require 'digest/md5'
require 'fileutils'
require 'open-uri'
require 'yaml'
require 'nodule/process'
require 'nodule/tempfile'
require 'nodule/util'
require 'cassandra'

module Nodule
  #
  # Run temporary instances of Apache Cassandra.
  # Generates random ports for rpc/storage and temporary directories for data,
  # commit logs, etc..
  #
  # The version of Cassandra is hard-coded to 1.0.8.
  #
  class Cassandra < Process
    attr_reader :tmp, :keyspace, :data, :caches, :commit, :pidfile, :config, :envfile

    # These two must match. Apache posts the md5's on the download site.
    VERSION = "1.0.8"
    MD5 = "676887f6d185689c3383908f3ad8e015"

    CASSANDRA   = "apache-cassandra-#{VERSION}"
    TARBALL     = "#{CASSANDRA}-bin.tar.gz"
    TARBALL_URL = "http://archive.apache.org/dist/cassandra/#{VERSION}/#{TARBALL}"

    # potential locations for caching the cassandra download
    CACHEDIRS = [
      File.join(ENV['HOME'], 'Downloads'),
      "/tmp",
    ]

    CLIENT_CONNECT_OPTIONS = {
      :connect_timeout => 10,
      :retries => 10,

      :exception_classes => [],
    }

    #
    # Create a new Nodule::Cassandra instance. Each instance will be its own single-node Cassandra instance.
    #
    # @param [Hash] opts the options for setup.
    # @option opts [String] :keyspace Keyspace name to create at startup.
    #
    def initialize(opts={})
      @keyspace   = opts[:keyspace] || "Nodule"
      #@keyspace   = opts[:keyspace] || "Nodule#{::Process.pid}"

      @temp = Nodule::Tempfile.new(:directory => true, :prefix => "nodule-cassandra-")
      @tmp = @temp.file

      @data = File.join(@tmp, 'data')
      @caches = File.join(@tmp, 'caches')
      @commit = File.join(@tmp, 'commitlogs')

      @jmx_port = Nodule::Util.random_tcp_port
      @rpc_port = Nodule::Util.random_tcp_port
      @storage_port = Nodule::Util.random_tcp_port
      @ssl_storage_port = Nodule::Util.random_tcp_port

      @pidfile = "#{@tmp}/#{CASSANDRA}/cassandra.pid"
      @cassbin = "#{@tmp}/#{CASSANDRA}/bin"
      @command = ["#{@cassbin}/cassandra", "-f", "-p", @pidfile]
      @config  = "#{@tmp}/#{CASSANDRA}/conf/cassandra.yaml"
      @envfile = "#{@tmp}/#{CASSANDRA}/conf/cassandra-env.sh"

      super(*@command, opts)
    end

    #
    # Downloads Cassandra tarball to memory from the Apache servers.
    # @return [String] binary string containing the tar/gzip data.
    #
    def download
      tardata = open(TARBALL_URL).read
      digest = Digest::MD5.hexdigest(tardata)

      unless digest == MD5
        raise "Expected MD5 #{MD5} but got #{digest}."
      end

      tardata
    end

    #
    # Write the tarball to a file locally. Finds a directory in the CACHEDIRS list.
    # @param [String] binary string containing tar/gzip data.
    # @return [String] full path of the file
    #
    def cache_tarball!(tardata)
      cachedir = (CACHEDIRS.select { |path| File.directory?(path) and File.writable?(path) })[0]
      cachefile = File.join(cachedir, TARBALL)
      File.open(cachefile, "wb").write(tardata)
      cachefile
    end

    #
    # Downloads Cassandra tarball from the Apache servers.
    # @param [String] full path to the tarball file
    #
    def untar!(tarball)
      system("tar -C #{@tmp} -xzf #{tarball}")
    end

    #
    # Rewrites portions of the stock Cassandra configuration. This should work fairly well over Cassandra
    # version bumps without editing as long as the Cassandra folks don't wildly change param names.
    # Modifies conf/cassandra.yaml and conf/cassandra-env.sh.
    #
    def configure!
      conf = YAML::load_file(@config)
      conf.merge!({
        "initial_token"          => 0,
        "partitioner"            => "org.apache.cassandra.dht.RandomPartitioner",
        # have to force ascii or YAML will come out as binary
        "data_file_directories"  => [@data.encode("us-ascii")],
        "commitlog_directory"    => @commit.encode("us-ascii"),
        "saved_caches_directory" => @caches.encode("us-ascii"),
        "storage_port"           => @storage_port.to_i,
        "ssl_storage_port"       => @ssl_storage_port.to_i,
        "listen_address"         => "127.0.0.1",
        "rpc_address"            => "127.0.0.1",
        "rpc_port"               => @rpc_port.to_i,
        # DSE doesn't work OOTB as a single node unless you switch to simplesnitch
        "endpoint_snitch"        => "org.apache.cassandra.locator.SimpleSnitch",
      })
      File.open(@config, "w") { |file| file.puts YAML::dump(conf) }

      # relocate the JMX port to avoid conflicts with running instances
      env = File.read(@envfile)
      env.sub!(/JMX_PORT=['"]?\d+['"]?/, "JMX_PORT=\"#{@jmx_port}\"")
      File.open(@envfile, "w") { |file| file.puts env }
    end

    #
    # Create a keyspace in the newly minted Cassandra instance.
    #
    def create_keyspace
      ksdef = CassandraThrift::KsDef.new(
        :name => @keyspace,
        :strategy_class => 'org.apache.cassandra.locator.SimpleStrategy',
        :replication_factor => 1,
        :cf_defs => []
      )
      client('system').add_keyspace ksdef
    end

    #
    # Run the download or untar the cached tarball. Configure, start Cassandra, and create
    # the keyspace.
    #
    def run
      FileUtils.mkdir_p @data
      FileUtils.mkdir_p @caches
      FileUtils.mkdir_p @commit

      cached = CACHEDIRS.select { |path| File.exists? File.join(path, TARBALL) }
      if cached.any?
        untar! File.join(cached.first, TARBALL)
      else
        file = cache_tarball! download
        untar! file
      end

      configure!
      super
      sleep 2 # wait for cassandra to start up
      create_keyspace
    end
    
    #
    # Stop cassandra with a signal, clean up with recursive delete.
    #
    def stop
      super
      @temp.stop
    end

    #
    # Setup and return a Cassandra client object.
    # @param [String] keyspace optional keyspace argument for the client connection
    # @return [Cassandra] connection to the temporary Cassandra instance
    #
    def client(ks=@keyspace)
      c = ::Cassandra.new(ks, self.to_s, CLIENT_CONNECT_OPTIONS)
      c.disable_node_auto_discovery!
      c
    end

    #
    # Stringify this class to the cassandra host/port string, e.g. "127.0.0.1:12345"
    # @return [String] Cassandra connection string.
    #
    def to_s
      "127.0.0.1:#{@rpc_port}"
    end
  end
end

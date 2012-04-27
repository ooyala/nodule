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
    attr_reader :tmp, :keyspace, :data, :caches, :commit, :pidfile, :cassbin, :config, :envfile, :rpc_port

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
    # @option opts [String] :keyspace Keyspace name to use as the default
    #
    def initialize(opts={})
      @keyspace   = opts[:keyspace] || "Nodule"

      @temp = Nodule::Tempfile.new(:directory => true, :prefix => "nodule-cassandra")
      @tmp = @temp.file

      @data = File.join(@tmp, 'data')
      @caches = File.join(@tmp, 'caches')
      @commit = File.join(@tmp, 'commitlogs')

      @host = "127.0.0.1" # will support 127.0.0.2 someday
      @jmx_port = Nodule::Util.random_tcp_port
      @rpc_port = Nodule::Util.random_tcp_port
      @storage_port = Nodule::Util.random_tcp_port
      @ssl_storage_port = Nodule::Util.random_tcp_port

      @casshome = "#{@tmp}/#{CASSANDRA}"
      @pidfile = "#{@casshome}/cassandra.pid"
      @cassbin = "#{@casshome}/bin"
      @command = ["#{@cassbin}/cassandra", "-f", "-p", @pidfile]
      @config  = "#{@casshome}/conf/cassandra.yaml"
      @envfile = "#{@casshome}/conf/cassandra-env.sh"
      @log4j   = "#{@casshome}/conf/log4j-server.properties"
      @logfile = "#{@tmp}/system.log"

      # This handler reads STDOUT to determine when Cassandra is ready for client
      # access. Coerce the stdout option into an array as necessar so options can
      # still be passed in.
      if opts[:stdout]
        unless opts[:stdout].kind_of? Array
          opts[:stdout] = [ opts.delete(:stdout) ]
        end
      else
        opts[:stdout] = []
      end

      # Watch Cassandra's output to be sure when it's available, obviously, it's a bit fragile
      # but (IMO) better than sleeping or poking the TCP port.
      @mutex = Mutex.new
      @cv = ConditionVariable.new
      opts[:stdout] << proc do |item|
        @mutex.synchronize do
          @cv.signal if item =~ /Listening for thrift clients/
        end
      end

      super({"CASSANDRA_HOME" => @casshome}, *@command, opts)
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
        "listen_address"         => @host.encode("us-ascii"),
        "rpc_address"            => @host.encode("us-ascii"),
        "rpc_port"               => @rpc_port.to_i,
        # DSE doesn't work OOTB as a single node unless you switch to simplesnitch
        "endpoint_snitch"        => "org.apache.cassandra.locator.SimpleSnitch",
      })
      File.open(@config, "w") { |file| file.puts YAML::dump(conf) }

      # relocate the JMX port to avoid conflicts with running instances
      env = File.read(@envfile)
      env.sub!(/JMX_PORT=['"]?\d+['"]?/, "JMX_PORT=\"#{@jmx_port}\"")
      File.open(@envfile, "w") { |file| file.puts env }

      # relocate the system.log
      log = File.read(@log4j)
      log.sub!(/log4j.appender.R.File=.*$/, "log4j.appender.R.File=#{@logfile}")
      File.open(@log4j, "w") do |file| file.puts log end
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
    # Run the download or untar the cached tarball. Configure then start Cassandra.
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

      # will start Cassandra process
      super

      # wait for Cassandra to say it's ready
      @mutex.synchronize do @cv.wait @mutex end
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

      yield(c) if block_given?

      c
    end

    #
    # Returns the fully-quailified cassandra-cli command with host & port set. If given a list of
    # arguments, they're tacked on automatically.
    # @param [Array] more_args additional command-line arguments
    # @return [Array] an argv-style array ready to use with Nodule::Process or Kernel.spawn
    #
    def cli_command(*more_args)
      [File.join(@cassbin, 'cassandra-cli'), '-h', @host, '-p', @rpc_port, more_args].flatten
    end

    #
    # Run a block with access to cassandra-cli's stdio.
    # @param [Array] more_args additional command-line arguments
    # @yield block with CLI attached
    # @option block [Nodule::Process] process Nodule::Process object wrapping the CLI
    # @option block [IO] stdin
    # @option block [IO] stdout
    # @option block [IO] stderr
    #
    def cli(*more_args)
      process = Process.new *cli_command(more_args)
      process.join_topology! @topology
      process.run
      yield process, process.stdin_pipe, process.stdout_pipe, process.stderr_pipe
      process.print "quit;\n" unless process.done?
      process.wait 3
      process.stop
    end

    #
    # Returns the fully-quailified nodetool command with host & JMX port set. If given a list of
    # arguments, they're tacked on automatically.
    # @param [Array] more_args additional command-line arguments
    # @return [Array] an argv-style array ready to use with Nodule::Process or Kernel.spawn
    #
    def nodetool_command(*more_args)
      [File.join(@cassbin, 'nodetool'), '-h', @host, '-p', @jmx_port, more_args].flatten
    end

    #
    # @param [Array] more_args additional command-line arguments
    # @yield block with CLI attached
    # @option block [Nodule::Process] process Nodule::Process object wrapping the CLI
    # @option block [IO] stdin
    # @option block [IO] stdout
    # @option block [IO] stderr
    #
    def nodetool(*more_args)
      process = Process.new *nodetool_command(more_args)
      process.join_topology! @topology
      process.run
      yield process, process.stdin_pipe, process.stdout_pipe, process.stderr_pipe
      process.wait 3
      process.stop
    end

    #
    # Stringify this class to the cassandra host/port string, e.g. "127.0.0.1:12345"
    # @return [String] Cassandra connection string.
    #
    def to_s
      [@host, @rpc_port].join(':')
    end
  end
end

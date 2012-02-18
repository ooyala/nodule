require 'socket'
require 'nodule/tap'
require 'nodule/actor'
require 'nodule/tempfile'

module Nodule
  class UnixSocket < Tempfile
    attr_reader :family

    def initialize(opts={})
      super(opts)
      @family = opts[:family] || :DGRAM
      @socket = Socket.new(:UNIX, @family, 0)
      @address = Addrinfo.unix(@file)
      @connected = false
    end

    #
    # sock1 = Nodule::UnixSocket.new
    # 
    def send(data)
      @socket.connect(@address) unless @connected
      @connected = true

      if @family == :DGRAM
        @socket.sendmsg(data, 0)
      else
        @socket.send(data, 0)
      end
    end

    def stop
      @socket.close
      super
    end
  end

  class UnixServer < Tempfile
    def run
      super
      @thread = Thread.new do
        begin
          server = Socket.new(:UNIX, @family, 0)
          address = Addrinfo.unix(@file)
          server.bind(address)

          message, = server.recvmsg(65536, 0) if sock
        rescue
          STDERR.puts $!.inspect, $@
        end
      end
    end

    def to_s
      @sockfile
    end
  end
end

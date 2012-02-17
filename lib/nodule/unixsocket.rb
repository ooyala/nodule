require 'socket'
require 'nodule/tap'
require 'nodule/actor'
require 'nodule/tempfile'

module Nodule
  class UnixSocket < Tempfile
    #
    # sock1 = Nodule::UnixSocket.new
    # 
    def send(data)
      socket = UNIXSocket.new(@file)
      socket.sendmsg(data, 0)
      socket.close
    end
  end

  class UnixServer < Tempfile
    def run
      super
      @thread = Thread.new do
        begin
          server = UNIXServer.new(@file)
          while @running
            begin # emulate blocking accept
              sock = server.accept_nonblock
            rescue IO::WaitReadable, Errno::EINTR
              IO.select([server])
            retry
            end
          end

          message, = sock.recvmsg_(65536, 0) if sock

          run_writers do |item|
            server.sendmsg(item, 0)
          end

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

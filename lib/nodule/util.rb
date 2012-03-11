require 'socket'

module Nodule
  module Util
    @seen = {}

    #
    # Try random ports > 10_000 looking for one that's free.
    # @param [Fixnum] max number of tries to find a free port
    # @return [Fixnum] port number
    #
    def self.random_tcp_port(max_tries=500)
      tries = 0

      while tries < max_tries
        port = random_port
        next if @seen.has_key? port

        socket = begin
          TCPServer.new port
        rescue Errno::EADDRINUSE
          @seen[port] = true
          tries += 1
          next
        end

        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
        socket.close
        return port
      end
    end

    #
    # Return a random integer between 10_000 and 65_534
    # @return [Fixnum]
    #
    def self.random_port
      rand(55534) + 10_000
    end
  end
end

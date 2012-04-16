require 'nodule/tempfile'
require 'ffi-rzmq'
require 'thread'

module Nodule
  #
  # A resource for setting up and testing ZeroMQ message flows. The most basic usage will provide
  # auto-generated IPC URI's, which can be handy for testing. More advanced usage uses the built-in
  # tap device to sniff messages while they're in-flight.
  #
  class ZeroMQ < Tempfile
    attr_reader :ctx, :uri, :method, :type, :limit, :error_count

    private

    def setsockopt(socket, option, value)
      if option == :hwm && ::ZMW::LibZMQ.version3?
        rc = socket.setsockopt(::ZMQ::SNDHWM, value)
        rc = socket.setsockopt(::ZMQ::RCVHWM, value) if rc > -1
      else
        rc = socket.setsockopt(option, value)
      end

      rc
    end

    public

    #
    # :uri - either :gen/:generate or a string, :gen means generate an IPC URI, a string
    #         must be a valid URI.
    # :limit - exit the read loop after :limit messages are received
    # :connect - create a socket and connect to the URI
    # :bind - create a socket and bind to the URI
    #
    # :connect and :bind are allowed at the same time and must be of the same socket type.
    #
    # For the rest of the options, see Hastur::Test::Resource::Base.
    #
    def initialize(opts)
      opts[:suffix] ||= '.zmq'

      super(opts)

      @ctx = ::ZMQ::Context.new
      @zmq_thread = nil
      @error_count = 0
      @sockprocs = []
      @limit = nil
      @timeout_started = false
      @stopped = false

      # Sockets cannot be used across thread boundaries, so use a ZMQ::PAIR socket both to synchronize thread
      # startup and pass writes form main -> thread. The .socket method will return the PAIR socket.
      @pipe_uri = "inproc://pair-#{Nodule.next_seq}"
      @pipe = @ctx.socket(::ZMQ::PAIR)
      @child = @ctx.socket(::ZMQ::PAIR)
      setsockopt(@pipe, :hwm, 1)
      setsockopt(@child, :hwm, 1)
      setsockopt(@pipe, ::ZMQ::LINGER, 1.0)
      setsockopt(@child, ::ZMQ::LINGER, 1.0)
      @pipe.bind(@pipe_uri)
      @child.connect(@pipe_uri)

      case opts[:uri]
        # Socket files are specified so they land in PWD, in the future we might want to specify a temp
        # dir, but that has a whole different bag of issues, so stick with simple until it's needed.
        when :gen, :generate
          @uri = "ipc://#{@file.to_s}"
        when String
          @uri = val
        else
          raise ArgumentError.new "Invalid URI specifier: (#{val.class}) '#{val}'"
      end

      if opts[:connect] and opts[:bind] and opts[:connect] != opts[:bind]
        raise ArgumentError.new "ZMQ socket types must be the same when enabling :bind and :connect"
      end

      # only set type and create a socket if :bind or :connect is specified
      # otherwise, the caller probably just wants to generate a URI, or possibly
      # use a pre-created socket? (not supported yet)
      if @type = (opts[:connect] || opts[:bind])
        @socket = @ctx.socket(@type)
        setsockopt(@socket, :hwm, 1)
        setsockopt(@socket, ::ZMQ::LINGER, 1.0)

        if opts[:connect]
          @sockprocs << proc { @socket.connect(@uri) } # deferred
        end

        if opts[:bind]
          @sockprocs << proc { @socket.bind(@uri) } # deferred
        end
      end

      if opts[:limit]
        @limit = opts[:limit]
      end
    end

    def run
      super
      return if @sockprocs.empty?

      # wrap the block in a block so errors don't simply vanish until join time
      @zmq_thread = Thread.new do
        Thread.current.abort_on_exception

        # sockets have to be created inside the thread that uses them
        @sockprocs.each { |p| p.call }

        _zmq_read()
        verbose "child thread #{Thread.current} shutting down"

        @child.close
        @socket.close if @socket
      end

      Thread.pass

      @stopped = @zmq_thread.alive? ? false : true
    end

    def socket
      @pipe
    end

    #
    # For PUB sockets only, subscribe to a prefix.
    # @param [String] subscription prefix, usually ""
    #
    def subscribe(subscription)
      @pipe.send_strings ["subscribe", subscription]
    end

    def done?
      @stopped
    end

    #
    # Wait for the ZMQ thread to exit on its own, mostly useful with :limit => Fixnum.
    #
    # This does not signal the child thread.
    #
    def wait(timeout=60)
      countdown = timeout.to_f

      while countdown > 0
        if @zmq_thread and @zmq_thread.alive?
          sleep 0.1
          countdown = countdown - 0.1
        else
          break
        end
      end

      super()
    end

    #
    # If the thread is still alive, force an exception in the thread and
    # continue to do the things stop does.
    #
    def stop!
      if @zmq_thread.alive?
        STDERR.puts "force stop! called, issuing Thread.raise"
        @zmq_thread.raise "force stop! called"
      end

      stop
      wait 1

      @zmq_thread.join if @zmq_thread
      @pipe.close if @pipe

      @stopped = true
    end

    #
    # send a message to the child thread telling it to exit and join the thread
    #
    def stop
      return if @stopped

      @pipe.send_strings(["exit"], 1)

      Thread.pass

      super

      @zmq_thread.join if @zmq_thread
      @pipe.close if @pipe

      @stopped = true
    end

    #
    # Return the URI generated/provided for this resource. For tapped devices, the "front" side
    # of the tap is returned.
    #
    def to_s
      @uri
    end

    private

    #
    # Run a poll loop (using the zmq poller) on a 1/5 second timer, reading data
    # from the socket and calling the registered procs.
    # If :limit was set, will exit after that many messages are seen/processed.
    # Otherwise, exits on the next iteration if the mutex is locked (which is done in stop).
    # Takes no arguments, doesn't return anything meaningful.
    #
    def _zmq_read
      return unless @socket
      @poller = ::ZMQ::Poller.new

      @poller.register_readable @socket
      @poller.register_readable @child

      # read on the socket(s) and call the registered reader blocks for every message, always using
      # multipart and converting to ruby strings to avoid ZMQ::Message cleanup issues.
      count = 0
      @running = true
      while @running
        rc = @poller.poll(1)
        unless rc > 0
          sleep 0.01
          next
        end

        @poller.readables.each do |sock|
          rc = sock.recv_strings messages=[]
          if rc > -1
            if sock == @socket
              count += 1
              run_readers(messages, self)
            # the main thread can send messages through to be resent or "exit" to shut down this thread
            elsif sock == @child
              if messages[0] == "exit"
                verbose "Got exit message. Exiting."
                @running = false
              elsif messages[0] == "subscribe"
                @socket.setsockopt ::ZMQ::SUBSCRIBE, messages[1]
              else
                @socket.send_strings messages
              end
            else
              raise "BUG: couldn't match socket to a known socket"
            end

            # stop reading after a set number of messages, regardless of whether there are any more waiting
            break if @limit and count >= @limit
            break unless @running
          else
            @error_count += 1
            break
          end
        end # @poller.readables.each

        break if @limit and count >= @limit
      end # while @running
    end
  end
end

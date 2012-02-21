require 'nodule/actor'
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

      # Sockets cannot be used across thread boundaries, so use a ZMQ::PAIR socket both to synchronize thread
      # startup and pass writes form main -> thread. The .socket method will return the PAIR socket.
      # This would be an inproc:// device, but they seem to lock up in this usage pattern, so go with IPC.
      @m2t_pair = Nodule::Tempfile.new # cleaned up in stop()
      @m2t_pair_uri = "ipc://#{@m2t_pair.to_s}"

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

        if opts[:connect]
          @sockprocs << proc { @socket.connect(@uri) } # deferred
        end
  
        if opts[:bind]
          @sockprocs << proc { @socket.bind(@uri) } # deferred
        end

        # deferred: create the IPC PAIR socket in the child thread
        @sockprocs << proc do
          @m2t_pair_rcv = @ctx.socket(ZMQ::PAIR)
          @m2t_pair_rcv.bind(@m2t_pair_uri)
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
        begin
          # sockets have to be created inside the thread that uses them
          @sockprocs.each { |p| p.call }

          _zmq_read()
          debug "child thread #{Thread.current} shutting down"

          @m2t_pair_rcv.close

          if @socket
            @socket.setsockopt(ZMQ::LINGER, 0)
            @socket.close
          end
        rescue
          STDERR.puts $!.inspect, $@
        end
      end

      # now create the main thread side immediately
      @m2t_pair_send = @ctx.socket(ZMQ::PAIR)
      @m2t_pair_send.connect(@m2t_pair_uri)
    end

    def _timeout(timeout=0)
      return if @timeout_started or timeout == 0
      @timeout_started = true

      Thread.new do
        sleep timeout
        if @zmq_thread.alive?
          @zmq_thread.terminate
          @zmq_thread.join
        end
      end
    end

    def socket
      @m2t_pair_send
    end

    #
    # Wait for the ZMQ thread to exit on its own, mostly useful with :limit => Fixnum.
    #
    def wait(timeout=0)
      timer = _timeout(timeout)
      @zmq_thread.join
      timer.join if timer
      super()
    end

    #
    # Set a mutex that causes the ZMQ thread to exit, join that thread, then call
    # any cleanup in Base.
    #
    def stop
      unless @sockprocs.empty?
        @m2t_pair_send.send_strings(["exit"])
        @m2t_pair_send.setsockopt(ZMQ::LINGER, 0)
        @m2t_pair_send.close
        @zmq_thread.join if @zmq_thread
      end

      @m2t_pair.stop
      @ctx.terminate
      super
    end

    #
    # Return the URI generated/provided for this resource. For tapped devices, the "front" side
    # of the tap is returned.
    #
    def to_s
      @uri
    end

    # write to the socket(s) if writer proces are defined in @writers
    # assume it's ready by the time we get here, which seems to generally work with zeromq
    #
    # one single-part:  r.add_writer proc { "a" }
    # many single-part: r.add_writer proc { ["a", "b", "c"] }
    # one multipart:    r.add_writer proc { [["a", "b"]] }
    # many multipart:   r.add_writer proc { [["a", "b"],["c","d"]] }
    def _zmq_write
      return if @writers.empty?
      run_writers do |output|
        # returned a list
        if output.respond_to? :each
          output.each do |item|
            # procs can send lists of lists to achieve multi-part output
            if item.respond_to? :map
              messages = item.map { |i| ZMQ::Message.new i }
              @socket.sendmsgs messages # ignore errors
              messages.each { |m| m.close }
            # otherwise, it's just a string or something with a sane to_s
            else
              @socket.send_string item.to_s
            end
          end
        # returned a single item, send it as a string
        else
          @socket.send_string output.to_s
        end
      end
    end

    #
    # Run a poll loop (using the zmq poller) on a 1/5 second timer, reading data
    # from the socket and calling the registered procs.
    # If :limit was set, will exit after that many messages are seen/processed.
    # Otherwise, exits on the next iteration if the mutex is locked (which is done in stop).
    #
    def _zmq_read
      return unless @socket
      @poller = ::ZMQ::Poller.new

      @poller.register_readable @socket
      @poller.register_readable @m2t_pair_rcv

      # read on the socket(s) and call the registered reader blocks for every message, always using
      # multipart and converting to ruby strings to avoid ZMQ::Message cleanup issues.
      count = 0
      @running = true
      while @running
        _zmq_write()

        rc = @poller.poll(0.2)
        unless rc > 0
          sleep 0.2
          next
        end

        @poller.readables.each do |sock|
          rc = sock.recv_strings messages=[]
          if rc > -1
            count += 1

            if sock == @socket
              run_readers(messages)
            # the main thread can send messages through to be resent or "exit" to shut down this thread
            elsif sock == @m2t_pair_rcv
              if messages[0] == "exit"
                @running = false
                return
              else
                @socket.send_strings messages
              end
            else
              raise "BUG: couldn't match socket to a known socket"
            end

            # stop reading after a set number of messages, regardless of whether there are any more waiting
            return if @limit and count == @limit
          else
            @error_count += 1
            break
          end

          break if @limit and count == @limit
        end
      end
    end
  end
end

require 'nodule/base'

module Nodule
  class LineIO < Base
    #
    # A few extra bits to help with handling IO objects (files, pipes, etc.), like setting
    # up a background thread to select() and read lines from it and call run_readers.
    #
    # @param [Hash{Symbol => IO,Symbol,Proc}] opts
    # @option opts [IO] :io required IO object, pipes & files should work fine
    #
    # @example
    # r, w = IO.pipe
    # nio = Nodule::Stdio.new :io => r, :run => true
    #
    def initialize(opts={})
      @running = false
      raise ArgumentError.new ":io is required and must be a descendent of IO" unless opts[:io].kind_of?(IO)
      @io = opts.delete(:io)

      super(opts)
    end

    #
    # Create a background thread to read from IO and call Nodule run_readers.
    #
    def run
      super

      Thread.new do
        begin
          @running = true # relies on the GIL
          while @running do
            ready = IO.select([@io], [], [], 0.2)
            unless ready.nil?
              line = @io.readline
              run_readers(line, self)
            end
          end
        rescue EOFError
          verbose "EOFError: #{@io} probably closed."
          @io.close
          Thread.current.exit
        rescue Exception => e
          STDERR.print "Exception in #{name} IO thread: #{e.inspect}\n"
          abort e
        end
      end

      wait_with_backoff 30 do @running end
    end

    #
    # simply calls print *args on the io handle
    # @param [String] see IO.print
    #
    def print(*args)
      @io.print(*args)
    end

    #
    # calls io.puts *args
    # @param [String] see IO.print
    #
    def puts(*args)
      @io.puts(*args)
    end
  end
end

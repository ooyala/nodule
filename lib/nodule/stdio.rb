require 'nodule/base'

module Nodule
  class Stdio < Base
    attr_reader :stdin, :stdout, :stderr

    def initialize(opts={})
      @running = false

      @stdin = opts[:in]
      @stdout = opts[:out]
      @stderr = opts[:err]

      @stdout_handler = Nodule::Base.new
      @stderr_handler = Nodule::Base.new
      @stdout_handler.add_readers(opts.delete(:stdout)) if opts[:stdout]
      @stderr_handler.add_readers(opts.delete(:stderr)) if opts[:stderr]

      super(opts)
    end

    def join_topology!(t)
      @stdout_handler.join_topology! t
      @stderr_handler.join_topology! t
      super(t)
    end

    #
    # Create a background thread to read from an IO and call Nodule run_readers.
    # @param [IO] io
    # @param [Nodule::Base] handler
    #
    def _io_thread(io, handler)
      Thread.new do
        Thread.current.abort_on_exception = true
        handler.run
        while @running do
          if _ready?([io], [], [], 0.1) and not io.eof?
            line = io.readline
            handler.run_readers(line, self)
          end
        end
      end
    end

    #
    # Run stdout/stderr handlers in a background thread.
    #
    def run
      return if @running
      @running = true

      @stdout_thread = _io_thread(@stdout, @stdout_handler)
      @stderr_thread = _io_thread(@stderr, @stderr_handler)

      super
    end

    def stop
      @running = false
      @stdout_handler.stop
      @stderr_handler.stop
      @stdout_thread.join
      @stderr_thread.join
    end
    alias :stop! :stop

    def wait(timeout=0)      _ready?([@stdout, @stderr], [@stdin], [], timeout) end
    def readable?(timeout=0) _ready?([@stdout,@stderr],  [],       [], timeout) end
    def stdout?(timeout=0)   _ready?([@stdout],          [],       [], timeout) end
    def stderr?(timeout=0)   _ready?([@stderr],          [],       [], timeout) end
    def writable?(timeout=0) _ready?([],                 [@stdin], [], timeout) end

    def _ready?(rd, wt, err, timeout)
      # filter out any closed/nil io's
      srd  = rd.reject  do |io| io.nil? or io.closed? end
      swt  = wt.reject  do |io| io.nil? or io.closed? end
      serr = err.reject do |io| io.nil? or io.closed? end

      ready = IO.select(srd, swt, serr, timeout)
      ready.respond_to? :any? and ready.any?
    end

    def print(*args)
      raise NotReadyError.new "stdin IO is not ready for writing" unless writable?
      @stdin.print(*args)
    end

    def puts(*args)
      raise NotReadyError.new "stdin IO is not ready for writing" unless writable?
      @stdin.puts(*args)
    end

    # might consider the slow/easy path and do 1-byte reads, that way newlines aren't required
    def output
      out = []
      while stdout?
        out << @stdout.readline
      end
      out
    end

    def errors
      out = []
      while stderr?
        out << @stderr.readline
      end
      out
    end

    def close
      @stdin.close  unless @stdin.nil?
      @stdout.close unless @stdout.nil?
      @stderr.close unless @stderr.nil?
    end

    def done?
      (not @running) and \
        (@stdin.nil? or @stdin.closed?) and \
        (@stdout.nil? or @stdout.closed?) and \
        (@stderr.nil? or @stderr.closed?)
    end
  end
end

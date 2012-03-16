require 'nodule/base'

module Nodule
  class Stdio < Base
    attr_reader :stdin, :stdout, :stderr
    attr_reader :stdout_proxy, :stderr_proxy

    def initialize(opts={})
      @threads = []
      @running = false
      @handlers = {}
      @mutex = Mutex.new
      @stdout_handler = opts.delete :stdout
      @stderr_handler = opts.delete :stderr

      super(opts)
    end

    #
    # Create a background thread to read from an IO and call Nodule run_readers.
    # @param [IO] io
    # @param [Proc, Nodule::Base] handler
    #
    def _run_handler(io, handler)
      name = io.to_s

      @threads << Thread.new do
        Thread.current.abort_on_exception = true

        @mutex.synchronize do
          @handlers[name] = Nodule::Base.new :reader => handler
          @handlers[name].topology = @topology
          @handlers[name].run
        end

        io.each do |line|
          @handlers[name].run_readers(line)
        end
      end
    end

    def run
      return if @running

      _run_handler(@stdout, @stdout_handler) if @stdout_handler
      _run_handler(@stderr, @stderr_handler) if @stderr_handler

      @running = true
    end

    def stop
      @handlers.each do |k,h| h.stop end
      @threads.each do |t| t.join end
      @running = false
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

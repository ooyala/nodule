require 'nodule/base'

module Nodule
  class Stdio < Base
    attr_reader :stdin, :stdout, :stderr

    def initialize(opts={})
      super(opts)
      @stdin  = opts[:stdin]
      @stdout = opts[:stdout]
      @stderr = opts[:stderr]
    end

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
      @stdin.print *args
    end

    def puts(*args)
      raise NotReadyError.new "stdin IO is not ready for writing" unless writable?
      @stdin.puts *args
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
    alias :stop  :close
    alias :stop! :close

    def done?
      (@stdin.nil? or @stdin.closed?) and (@stdout.nil? or @stdout.closed?) and (@stderr.nil? or @stderr.closed?)
    end
  end
end

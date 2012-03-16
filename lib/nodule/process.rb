require 'nodule/version'
require 'nodule/stdio'

module Nodule
  class ProcessNotRunningError < StandardError; end
  class ProcessAlreadyRunningError < StandardError; end
  class ProcessStillRunningError < StandardError; end
  class TopologyUnknownSymbolError < StandardError; end

  class Process < Stdio
    attr_reader :argv, :pid, :started, :ended
    attr_accessor :topology

    # @param [Array] command, argv
    # @param [Hash] opts
    # @option opts [Boolean] :run run immediately
    # @option opts [Boolean] :verbose print verbose information to STDERR
    def initialize(*argv)
      @opts = argv[-1].is_a?(Hash) ? argv.pop : {}
      @env = argv[0].is_a?(Hash) ? argv.shift : {}
      @status = nil
      @started = nil
      @ended = nil
      @pid = nil
      @argv = argv
      @verbose = @opts[:verbose]
      run if @opts[:run]
      # don't call super, stdio is set up in run()
    end

    # convert symbol arguments to the to_s result of a topology item if it exists,
    # run procs, and flatten enumerbles, so
    # :foobar will access the topology's entry for :foobar and call .to_s on it
    # proc { "abc" } will become "abc"
    # ['if=', :foobar] will resolve :foobar (this is recursive) and join all the results with no padding
    # anything left unmatched will be coerced into a string with .to_s
    def _apply_topology(arg)
      # only symbols are auto-translated to resource strings, String keys intentionally do not match
      if arg.kind_of? Symbol
        if @topology.has_key? arg
          @topology[arg].to_s
        else
          raise TopologyUnknownSymbolError.new "Unresolvable topology symbol, :#{arg}"
        end
      # sub-lists are recursed then joined with no padding, so:
      # ["if=", :foo] would become "if=value"
      elsif arg.respond_to? :map
        new = arg.map { |a| _apply_topology(a) }
        new.join('')
      else
        arg.to_s
      end
    end

    def run
      raise ProcessAlreadyRunningError.new if @pid

      argv = @argv.map { |arg| _apply_topology(arg) }

      # Simply calling spawn with *argv isn't good enough, it really needs the command
      # to be a completeley separate argument. This is likely due to a bug in spawn().
      command = argv.shift

      _verbose "Spawning: #{command} #{argv.join(' ')}"

      @stdin_r, @stdin    = IO.pipe
      @stdout,  @stdout_w = IO.pipe
      @stderr,  @stderr_w = IO.pipe

      @pid = spawn(@env, command, *argv,
        :in  => @stdin_r,
        :out => @stdout_w,
        :err => @stderr_w,
      )

      @started = Time.now

      @stdin_r.close
      @stdout_w.close
      @stderr_w.close

      # don't return until the process shows up or 10 seconds go by (probably failure)
      wait(10)
    end

    #
    # Clear all of the state and prepare to be able to .run again.
    # Raises ProcessStillRunningError if the child is still running.
    #
    def reset
      raise ProcessStillRunningError.new unless done?
      @pid = nil
      close # Stdio.close
    end

    def _kill(sig)
      # Do not use negative signals. You will _always_ get ESRCH for child processes, since they are
      # by definition not process group leaders, which is usually synonymous with the process group id
      # that "kill -9 $PID" relies on.  See kill(2).
      raise ArgumentError.new "negative signals are wrong and unsupported" unless sig > 0
      raise ProcessNotRunningError.new unless @pid

      _verbose "Sending signal #{sig} to process #{@pid}."
      ::Process.kill(sig, @pid)
      # do not catch ESRCH - ESRCH means we did something totally buggy, likewise, an exception
      # should fire if the process is not running since there's all kinds of code already checking
      # that it is running before getting this far.
    end

    #
    # Call Process.waitpid2, save the status (accessible with obj.status) and return just the pid value
    # returned by waitpid2.
    #
    def waitpid(flag=::Process::WNOHANG)
      raise ProcessNotRunningError.new unless @pid
      raise ProcessNotRunningError.new if @status

      pid, @status = ::Process.waitpid2(@pid, flag)

      # this is as accurate as we can get, and it will generally be good enough for test work
      @ended = Time.now if pid == @pid

      pid
    end

    #
    # Call waitpid and block until the process exits or timeout is reached.
    #
    alias :iowait :wait
    def wait(timeout=nil)
      pid = nil # silence warning
      if timeout and timeout > 0
        interval = 0.01
        countdown = timeout

        while countdown > 0
          pid = waitpid(::Process::WNOHANG)
          break if done?
          # back off the sleep time up to 1/4 the timeout
          sleep (interval < (timeout/4.0) ? (interval += interval) : interval)
          countdown -= interval
        end
      else
        # block indefinitely
        pid = waitpid(0)
      end
      return pid
    end

    #
    # Send SIGTERM (15) to the child process, sleep 1/25 of a second, then call waitpid. For well-behaving
    # processes, this should be enough to make it stop.
    # Returns true/false just like done?
    #
    def stop
      return if done?
      _kill 15 # never negative!
      sleep 0.05
      @pid == waitpid
    end

    #
    # Send SIGKILL (9) to the child process, sleep 1/10 of a second, then call waitpid and return.
    # Returns true/false just like done?
    #
    def stop!
      raise ProcessNotRunningError.new unless @pid
      return if done?

      _kill 9 # never negative!
      sleep 0.1
      @pid == waitpid
    end

    #
    # Return Process::Status as returned by Process::waitpid2.
    #
    def status
      raise ProcessNotRunningError.new "Called .status before .run." unless @pid
      waitpid unless @status
      @status
    end

    #
    # Check whether the process has exited or been killed and cleaned up.
    # Calls waitpid2 behind the scenes if necessary.
    # Throws ProcessNotRunningError if called before .run.
    #
    alias :iodone? :done?
    def done?
      raise ProcessNotRunningError.new "Called .done? before .run." unless @pid
      waitpid unless @status
      return true if @status
      waitpid == @pid
    end

    #
    # Return the elapsed time in milliseconds.
    #
    def elapsed
      raise ProcessNotRunningError.new unless @started
      raise ProcessStillRunningError.new unless @ended
      @ended - @started
    end

    #
    # Return most of the data about the process as a hash. This is safe to call at any point.
    #
    def to_hash
      {
        :argv    => @argv,
        :started => @started.to_i,
        :ended   => @ended.to_i,
        :elapsed => elapsed,
        :pid     => @pid,
        :retval  => ((@status.nil? and @status.exited?) ? nil : @status.exitstatus)
     }
    end

    #
    # Returns the command as a string.
    #
    def to_s
      @argv.join(' ')
    end

    #
    # Returns to_hash.inspect
    #
    def inspect
      to_hash.inspect
    end
  end
end

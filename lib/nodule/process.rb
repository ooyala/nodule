require 'nodule/version'

module Nodule
  class ProcessNotRunningError < StandardError; end
  class ProcessAlreadyRunningError < StandardError; end
  class ProcessStillRunningError < StandardError; end

  class Process
    attr_reader :argv, :pid, :started, :ended
    attr_reader :stdin, :stdout, :stderr

    def _convert(arg, topology)
      # only symbols are auto-translated to resource strings, String keys intentionally do not match
      if arg.kind_of? Symbol and topology.has_key? arg
        topology[arg].to_s
      # sub-lists are recursed then joined with no padding, so:
      # ["if=", :foo] would become "if=value"
      elsif arg.respond_to? :map
        new = arg.map { |a| _convert(a, topology) }
        new.join('')
      else
        arg.to_s
      end
    end

    def initialize(*argv)
      opts = argv[-1].respond_to?(:key) ? argv.pop : {}
      topology = argv[0].kind_of?(Nodule::Topology) ? argv.shift : nil

      @argv = argv.map { |arg| _convert(arg, topology) }

      @mutex = Mutex.new
      @threads = []
      @status = nil
      @started = nil
      @ended = nil
      @stdout_handler = _stdio_arg(opts, :stdout, topology)
      @stderr_handler = _stdio_arg(opts, :stderr, topology)
    end

    def _stdio_arg(opts, key, topology)
      out = nil
      if opts[key].kind_of? Proc
        out = Nodule::Actor.new(:reader => opts[key])
      elsif opts[key]
        if topology.has_key? opts[key]
          out = topology[opts[key]]
        else
          raise ArgumentError.new "Invalid value for :#{key} '#{opts[key].inspect}'"
        end
      end
    end

    def run
      raise ProcessAlreadyRunningError.new if @pid

      @stdin_r, @stdin    = IO.pipe
      @stdout,  @stdout_w = IO.pipe
      @stderr,  @stderr_w = IO.pipe

      # Simply calling spawn with *argv isn't good enough, it really needs the command
      # to be separate and I haven't dug all the way into why that is.
      @pid = spawn(@argv[0], *@argv[1..-1],
        :in  => @stdin_r,
        :out => @stdout_w,
        :err => @stderr_w,
      )

      @started = Time.now

      if @stdout_handler.respond_to? :call
        @threads << Thread.new do
          begin
            @stdout.lines { |line| @stdout_handler.run_readers(line) }
          rescue 
            STDERR.puts $!.inspect, $@
          end
        end
      end

      if @stderr_handler.respond_to? :call
        @threads << Thread.new do
          begin
            @stderr.lines { |line| @stderr_handler.run_readers(line) }
          rescue 
            STDERR.puts $!.inspect, $@
          end
        end
      end

      @stdin_r.close
      @stdout_w.close
      @stderr_w.close
    end

    #
    # puts to the stdin of the child process
    #
    def puts(*args)
      @stdin.puts *args
    end

    #
    # Read all of the data from stdout/stderr of the child process in one go.
    # Will raise ProcessStillRunningError if the process is still running, since otherwise this method
    # would block.
    #
    def slurp
      raise ProcessStillRunningError.new "Cannot slurp() until the process is done." unless done?
      stdout = @stdout_handler.respond_to? :call ? nil : @stdout.lines
      stderr = @stderr_handler.respond_to? :call ? nil : @stderr.lines
      return stdout, stderr
    end

    #
    # Clear all of the state and prepare to be able to .run again.
    # Raises ProcessStillRunningError if the child is still running.
    #
    def reset
      raise ProcessStillRunningError.new unless done?
      @pid = nil
      @stdin.close
      @stdout.close
      @stderr.close
    end

    def _kill(sig)
      # Do not use negative signals. You will _always_ get ESRCH for child processes, since they are
      # by definition not process group leaders, which is usually synonymous with the process group id
      # that "kill -9 $PID" relies on.  See kill(2).
      raise ArgumentError.new "negative signals are wrong and unsupported" unless sig > 0
      raise ProcessNotRunningError.new unless @pid

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
    # Call blocking waitpid and block until the process exits.
    #
    def wait
      waitpid(0)
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
    def done?
      raise ProcessNotRunningError.new "Called .done? before .run." unless @pid
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

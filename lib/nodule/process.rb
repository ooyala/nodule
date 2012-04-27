require 'nodule/version'
require 'nodule/line_io'

module Nodule
  class ProcessNotRunningError < StandardError; end
  class ProcessAlreadyRunningError < StandardError; end
  class ProcessStillRunningError < StandardError; end
  class TopologyUnknownSymbolError < StandardError; end

  class Process < Base
    attr_reader :argv, :pid, :started, :ended
    attr_accessor :topology

    # @param [Array] command, argv
    # @param [Hash] opts
    def initialize(*argv)
      @opts = argv[-1].is_a?(Hash) ? argv.pop : {}
      @env = argv[0].is_a?(Hash) ? argv.shift : {}
      @status = nil
      @started = -1   # give started and ended default values
      @ended = -2
      @pid = nil
      @argv = argv
      @stdout_opts = @opts.delete(:stdout) || :capture
      @stderr_opts = @opts.delete(:stderr) || :capture

      super(@opts)
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
      # raise exception only if the start time comes after the end time
      if @started > @ended
        raise ProcessAlreadyRunningError.new if @pid
      end

      argv = @argv.map { |arg| _apply_topology(arg) }

      # Simply calling spawn with *argv isn't good enough, it really needs the command
      # to be a completeley separate argument. This is likely due to a bug in spawn().
      command = argv.shift

      verbose "Spawning: #{command} #{argv.join(' ')}"

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

      @stdout_handler = Nodule::LineIO.new :io => @stdout, :reader => @stdout_opts, :topology => @topology, :run => true
      @stderr_handler = Nodule::LineIO.new :io => @stderr, :reader => @stderr_opts, :topology => @topology, :run => true

      Thread.pass

      super
    end

    #
    # Clear all of the state and prepare to be able to .run again.
    # Raises ProcessStillRunningError if the child is still running.
    #
    def reset
      raise ProcessStillRunningError.new unless done?
      @stdout_handler.stop
      @stderr_handler.stop
      close
      @pid = nil
    end

    def _kill(sig)
      # Do not use negative signals. You will _always_ get ESRCH for child processes, since they are
      # by definition not process group leaders, which is usually synonymous with the process group id
      # that "kill -9 $PID" relies on.  See kill(2).
      raise ArgumentError.new "negative signals are wrong and unsupported" unless sig > 0
      raise ProcessNotRunningError.new unless @pid

      verbose "Sending signal #{sig} to process #{@pid}."
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
      raise ProcessNotRunningError.new "pid is not known" unless @pid
      raise ProcessNotRunningError.new "process seems to have exited #{@status.inspect}" if @status

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

      # block indefinitely on nil/0 timeout
      unless timeout
        return waitpid(0)
      end

      wait_with_backoff timeout do
        if @status
          true
        else
          pid = waitpid(::Process::WNOHANG)
          done?
        end
      end

      pid
    end

    #
    # Send SIGTERM (15) to the child process, sleep 1/25 of a second, then call waitpid. For well-behaving
    # processes, this should be enough to make it stop.
    # Returns true/false just like done?
    #
    def stop
      return if done?
      _kill 15 # never negative!
      @stdout_handler.stop
      @stderr_handler.stop
      sleep 0.05
      @pid == waitpid
      close
    end

    #
    # Send SIGKILL (9) to the child process, sleep 1/10 of a second, then call waitpid and return.
    # Returns true/false just like done?
    #
    def stop!
      raise ProcessNotRunningError.new unless @pid
      return if done?

      _kill 9 # never negative!
      @stdout_handler.stop!
      @stderr_handler.stop!
      sleep 0.1
      @pid == waitpid
      close
    end

    #
    # Return Process::Status as returned by Process::waitpid2.
    #
    def status
      raise ProcessNotRunningError.new "#@prefix called .status before .run." unless @pid
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
      raise ProcessNotRunningError.new "#@prefix called .done? before .run." unless @pid
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
    # Returns whether or not any stdout has been captured.
    # Will raise an exception if capture is not enabled.
    # proxies: Nodule::Base.output?
    # @return [TrueClass,FalseClass]
    #
    def stdout?
      @stdout_handler.output?
    end
    alias :output? :stdout?

    #
    # Get all currently captured stdout. Does not clear the buffer.
    # proxies: Nodule::Base.output
    # @return [Array{String}]
    #
    def stdout
      @stdout_handler.output
    end
    alias :output :stdout

    #
    # Get all currently captured stdout. Resets the buffer and counts.
    # proxies: Nodule::Base.output!
    # @return [Array{String}]
    #
    def stdout!
      @stdout_handler.output!
    end

    #
    # Clear the stdout buffer and reset the counter.
    # proxies: Nodule::Base.clear!
    #
    def clear_stdout!
      @stdout_handler.clear!
    end
    alias :clear! :clear_stdout!

    #
    # Proxies to stdout require_read_count.
    #
    def require_stdout_count(count, max_sleep=10)
      @stdout_handler.require_read_count count, max_sleep
    end
    alias :require_read_count :require_stdout_count

    #
    # Returns whether or not any stderr has been captured.
    # Will raise an exception if capture is not enabled.
    # proxies: Nodule::Base.output?
    # @return [TrueClass,FalseClass]
    #
    def stderr?
      @stderr_handler.output?
    end

    #
    # Get all currently captured stderr. Does not clear the buffer.
    # proxies: Nodule::Base.output
    # @return [Array{String}]
    #
    def stderr
      @stderr_handler.output
    end

    #
    # Get all currently captured stderr. Resets the buffer and counts.
    # proxies: Nodule::Base.output!
    # @return [Array{String}]
    #
    def stderr!
      @stderr_handler.output!
    end

    #
    # Clear the stderr buffer and reset the counter.
    # proxies: Nodule::Base.clear!
    #
    def clear_stderr!
      @stderr_handler.clear!
    end

    #
    # Proxies to stderr require_read_count.
    #
    def require_stderr_count(count, max_sleep=10)
      @stderr_handler.require_read_count count, max_sleep
    end

    #
    # Write the to child process's stdin using IO.print.
    # @param [String] see IO.print
    #
    def print(*args)
      @stdin.print(*args)
    end

    #
    # Write the to child process's stdin using IO.puts.
    # @param [String] see IO.puts
    #
    def puts(*args)
      @stdin.puts(*args)
    end

    #
    # Access the STDIN pipe IO object of the handle.
    # @return [IO]
    #
    def stdin_pipe
      @stdin
    end

    #
    # Access the STDOUT pipe IO object of the handle.
    # @return [IO]
    #
    def stdout_pipe
      @stdout
    end

    #
    # Access the STDERR pipe IO object of the handle.
    # @return [IO]
    #
    def stderr_pipe
      @stderr
    end

    #
    # Close all of the pipes.
    #
    def close
      @stdin.close rescue nil
      @stdout.close rescue nil
      @stderr.close rescue nil
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

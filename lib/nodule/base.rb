require 'nodule/version'
require 'nodule/topology'

module Nodule
  @sequence = 0
  def self.next_seq
    @sequence += 1
  end

  class Base
    attr_reader :readers, :running, :read_count, :topology
    attr_accessor :prefix

    #
    # Create a new Nodule handler. This is meant to be a bass class for higher-level
    # Nodule types.
    #
    # @param [Hash{Symbol => String,Symbol,Proc}] opts
    # @option opts [String] :prefix text prefix for output/logs/etc.
    # @option opts [Symbol, Proc] :reader a symbol for a built-in reader, e.g. ":drain" or a proc
    # @option opts [Enumerable] :readers a list of readers instead of one :reader
    # @option opts [TrueClass] :run run immediately
    # @option opts [TrueClass] :verbose print verbose information to STDERR
    #
    def initialize(opts={})
      @read_count = 0
      @readers ||= []
      @output  ||= []
      @prefix  = opts[:prefix] || ''
      @verbose = opts[:verbose]
      @done    = false
      @topology = nil
      @capture_enabled = false

      add_readers(opts[:reader]) if opts[:reader]

      run if opts[:run]
    end

    def join_topology!(t, name='')
      @topology = t
      @prefix = name if @prefix.nil? || @prefix.empty?
    end

    def run
      @done = false

      unless @topology
        @toplogy = Nodule::Topology.new(:auto => self)
      end

      # automatically determine a prefix for console output based on the key name known to the topology
      if name = @topology.key(self)
        @prefix = "[#{name}]: "
      end
    end

    def stop
      @done = true
    end

    def stop!
      @done = true
    end

    def done?
      @done
    end

    def wait(timeout=nil)
    end

    #
    # Returns whether or not any output has been captured.
    # Will raise an exception if capture is not enabled.
    # @return [TrueClass,FalseClass]
    #
    def output?
      raise "output is not captured unless you enable :capture" unless @capture_enabled
      @output.any?
    end

    #
    # Returns a copy of currently captured output. Line data is not chomped or anything of the sort.
    # Will raise an exception if capture is not enabled.
    # @return [Array<String>]
    #
    def output
      raise "output is not captured unless you enable :capture" unless @capture_enabled
      @output.clone
    end

    #
    # Returns the captured output and clears the buffer (just like clear! but with a return value).
    # Will raise an exception if capture is not enabled.
    # @return [Array<String>]
    #
    def output!
      raise "output is not captured unless you enable :capture" unless @capture_enabled
      out = @output.clone
      clear!
      out
    end

    #
    # Reset the read count to zero and clear any captured output.
    #
    def clear!
      @read_count = 0
      @output.clear
    end

    #
    # A dead-simple backoff loop. Calls your block every @sleeptime seconds, increasing the sleep
    # time by sleeptime every iteration, up to timeout, at which point false will be returned. If
    # the block returns an non-false/nil value, it is returned.
    # @param [Float,Fixnum] timeout
    # @param [Float,Fixnum] sleeptime
    # @yield block that returns false to continue waiting, non-false to return that value
    # @return block return value or false if timeout
    #
    def wait_with_backoff(timeout, sleeptime=0.01)
      raise "a block to execute on each iteration is required" unless block_given?
      started = Time.now
      loop do
        val = yield
        return val if val
        return false if Time.now - started > timeout
        sleep sleeptime
        if sleeptime < timeout / 4
          sleeptime += sleeptime
        end
      end
    end
    # temporary 2012-04-27, remove after cleaning up all users of decay()
    alias :decay, :wait_with_backoff

    #
    # Wait in a sleep(0.1) loop for the number of reads on the handler to reach <count>.
    # Returns when the number of reads is given. On timeout, if a block was provided,
    # it's called before return. Otherwise, an exception is raised.
    # Has no impact on normal readers.
    #
    # @param [Fixnum] count how many reads to wait for
    # @param [Fixnum] max_sleep maximum number of seconds to wait for the count
    # @yield optional block to run on timeout
    # @example act.require_read_timeout 1, 10 do { fail }
    # @example act.require_read_timeout 1, 10 rescue nil
    #
    def require_read_count(count, max_sleep=10)
      started = Time.now
      while @read_count < count
        sleep 0.1
        if Time.now - started >= max_sleep
          if block_given?
            yield
          else
            raise "Timeout!"
          end
        end
      end
    end

    #
    # Add a reader action. Can be a block which will be executed for each unit of input, :capture
    # to capture all items emitted by the target to a list (accessible with .output), :ignore, or
    # nil (which will be ignored).
    # @param [Symbol, Proc] action Action to take on each item read from the handler
    # @option action [Symbol] :capture capture the items into an array (access with .output)
    # @option action [Symbol] :drain read items but throw them away
    # @option action [Symbol] :stderr print the item to stderr (with prefix, in color)
    # @option action [Symbol] :ignore don't do anything
    # @option action [Proc] run the block, passing it the item (e.g. a line of stdout)
    # @yield optionally pass a proc in with normal block syntax
    #
    def add_reader(action=nil, &block)
      if block_given?
        @readers << block
        return unless action
      end

      if action.respond_to? :call
        @readers << action
      elsif action == :capture
        @capture_enabled = true
        @readers << proc { |item| @output.push(item) }
      elsif action == :drain
        @readers << proc { |_| }
      elsif action == :ignore
      # nothing to do here
      # if it's an unrecognized symbol, defer resolution against the containing topology
      elsif action.kind_of? Symbol
        @readers << proc do |item|
          raise "Topology is not set up!" unless @topology
          raise ":#{action} is not a valid topology symbol in #{@topology.to_hash.inspect}" unless @topology.has_key?(action)
          @topology[action].run_readers(item, self)
        end
      else
        raise ArgumentError.new "Invalid add_reader class: #{action.class}"
      end
    end

    #
    # Add reader arguments with add_reader. Can be a single item or list.
    # @param [Array<Symbol,Proc,Nodule::Base>] args
    #
    def add_readers(*args)
      args.flatten.each do |reader|
        add_reader(reader)
      end
    end

    #
    # Run all of the registered reader blocks. The block should expect a single argument
    # that is an item of input. If the block has an arity of two, it will also be handed
    # the nodule object provided to run_readers (if it was provided; no guarantee is made that
    # it will be available). The arity-2 version is provided mostly as a clean way for
    # Nodule::Console to add prefixes to output, but could be useful elsewhere.
    # @param [Object] item the item to pass to the readers, often a String (but could be anything)
    # @param [Nodule::Base] handler that generated the item, optional, untyped
    #
    def run_readers(item, src=nil)
      @read_count += 1
      verbose "READ(#{@read_count}): #{item}"
      @readers.each do |reader|
        if reader.arity == 2
          reader.call(item, src)
        else
          reader.call(item)
        end
      end
    end

    #
    # Verbose Nodule output.
    # @param [Array<String>] out strings to output, will be joined with ' '
    #
    def verbose(*out)
      if @verbose
        if @topology.respond_to? :[] and @topology[@verbose]
          @topology[@verbose].run_readers out.join(' ')
        else
          STDERR.print "#{out.join(' ')}\n"
        end
      end
    end
  end
end

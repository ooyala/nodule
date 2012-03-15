require 'nodule/version'
require 'nodule/topology'

module Nodule
  @sequence = 0
  def self.next_seq
    @sequence += 1
  end

  class Actor
    attr_reader :readers, :writers, :input, :output, :running, :read_count
    attr_accessor :topology, :prefix
    @@mutex = Mutex.new
    @@debug = Mutex.new

    #
    # Create a new Actor.
    # @param [Hash{Symbol => String,Symbol,Proc}] opts
    # @option opts [String] :prefix text prefix for output/logs/etc.
    # @option opts [Symbol, Proc] :reader a symbol for a built-in reader, e.g. ":drain" or a proc
    # @option opts [Enumerable] :readers a list of readers instead of one :reader
    #
    def initialize(opts={})
      @read_count = 0
      @readers ||= [ proc { |_| @read_count += 1 } ]
      @writers ||= []
      @input   ||= []
      @output  ||= []
      @debug   = opts[:debug]
      @done    = false
      @topology = nil
      @rmutex = Mutex.new
      @wmutex = Mutex.new

      # only check for console color support once rather than for every line of output
      # @prefix will be filled in when run() is called so it can grab the key from the topology
      @prefix = opts[:prefix].to_s || ''
      if @prefix.respond_to? :color
        @to_console = proc { |item| STDERR.puts "#{@prefix}#{item}".color(:cyan) }
      else
        @to_console = proc { |item| STDERR.puts "#{@prefix}#{item}" }
      end

      add_reader(opts[:reader]) if opts[:reader]
      add_writer(opts[:writer]) if opts[:writer]
    end

    def run
      @done = false

      # this allows for standalone actors in an automatic one-node topology
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
    # Wait in a sleep(0.1) loop for the number of reads on the actor to reach <count>.
    # Returns when the number of reads is given. On timeout, if a block was provided,
    # it's called before return. Otherwise, an exception is raised.
    #
    # e.g. act.require_read_timeout 1, 10 do { fail }
    # e.g. act.require_read_timeout 1, 10 rescue nil
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
    # Add a writer action. Can be a block which will be executed, with its output emitted
    # to the target, a list of things to write to the target, :ignore or nil (which is ignored).
    #
    def add_writer(action=nil, &block)
      if block_given?
        @writers << block
      end

      if action.respond_to? :call
        @writers << action
      elsif action.kind_of? Symbol
        @writers << proc { |item| @topology[action].run_writers(item) }
      elsif action == :ignore or action.nil?
        # nothing to do here
      else
        raise ArgumentError.new "Invalid add_writer class: #{action.class}"
      end
    end

    #
    # Add a reader action. Can be a block which will be executed for each unit of input, :capture
    # to capture all items emitted by the target to a list (accessible with .output), :ignore, or
    # nil (which will be ignored).
    # @param [Symbol, Proc] action Action to take on each item read from the actor
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
        @readers << proc { |item| @output.push(item) }
      elsif action == :drain
        @readers << proc { |_| } # make sure there's at least one proc
      elsif action == :stderr
        @readers << @to_console
      elsif action == :ignore or action.nil?
        # nothing to do here
      # if it's an unrecognized symbol, defer resolution against the containing topology
      elsif action.kind_of? Symbol
        @readers << proc do |item|
          raise ArgumentError.new "Cannot resolve invalid topology symbol, ':#{item}'." unless @topology[action]
          @topology[action].run_readers(item, self)
        end
      else
        raise ArgumentError.new "Invalid add_reader class: #{action.class}"
      end
    end

    def synchronize(&block)
      @@mutex.synchronize(&block)
    end

    #
    # Run all of the registered reader blocks. The block should expect a single argument
    # that is an item of input. If the block has an arity of two, it will also be handed
    # the actor object provided to run_readers (if it was provided; no guarantee is made that
    # it will be available). The arity-2 version is provided mostly as a clean way for
    # Nodule::Console to add prefixes to output, but could be useful elsewhere.
    # @param [Object] item the item to pass to the readers, often a String (but could be anything)
    # @param [Nodule::Actor] actor that generated the item, optional, untyped
    #
    def run_readers(item, actor=nil)
      @rmutex.synchronize do
        @readers.each { |r| debug "running action: #{r}" }

        @readers.each do |reader|
          if reader.arity == 2
            reader.call(item, actor)
          else
            reader.call(item)
          end
        end
      end
    end

    def run_writers
      @wmutex.synchronize do
        @writers.each do |writer|
          writer.call(item)
        end
      end
    end

    #
    # semi-intelligent debug output for Nodule::Actors
    # @param [Array] args
    #
    def debug(*args)
      return unless @debug or ENV['DEBUG']

      if args.respond_to?(:one?) and args.one?
         message = "#{@prefix}#{args[0]}".color(:red)
      else
         message = "#{@prefix}#{args.inspect}".color(:red)
      end

      @@debug.synchronize do
        if message.respond_to? :color
          STDERR.puts message.color(:red)
        else
          STDERR.puts message
        end
      end
    end
  end
end

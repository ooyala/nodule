require 'nodule/version'
require 'nodule/topology'

module Nodule
  @sequence = 0
  def self.next_seq
    @sequence += 1
  end

  class Actor
    attr_reader :readers, :writers, :input, :output, :running
    attr_accessor :topology
    @@mutex = Mutex.new
    @@debug = Mutex.new

    def initialize(opts={})
      @readers ||= []
      @writers ||= []
      @input   ||= []
      @output  ||= []
      @debug   = opts[:debug]
      @done    = false
      @topology = nil
      @rmutex = Mutex.new
      @wmutex = Mutex.new

      @want_reader_output = opts[:capture_readers]
      @want_writer_output = opts[:capture_writers]

      # only check for console color support once rather than for every line of output
      # console_prefix will be filled in when run() is called so it can grab the key
      # from the topology
      @console_prefix = ''
      if @console_prefix.respond_to? :color
        @to_console = proc { |item| STDERR.puts "#{@console_prefix}#{item}".color(:cyan) }
      else
        @to_console = proc { |item| STDERR.puts "#{@console_prefix}#{item}" }
      end

      add_reader(opts[:reader]) if opts[:reader]
      if opts[:readers].respond_to? :each
        opts[:readers].each { |a| add_action(@readers, a) }
      end

      add_writer(opts[:writer]) if opts[:writer]
      if opts[:writers].respond_to? :each
        opts[:writers].each { |a| add_action(@writers, a) }
      end
    end

    def debug(*args)
      return unless @debug or ENV['DEBUG']

      if args.respond_to?(:one?) and args.one?
         message = "#{@console_prefix}#{args[0]}".color(:red)
      else
         message = "#{@console_prefix}#{args.inspect}".color(:red)
      end

      @@debug.synchronize do
        if message.respond_to? :color
          STDERR.puts message.color(:red)
        else
          STDERR.puts message
        end
      end
    end

    def run
      @done = false

      # this allows for standalone actors in an automatic one-node topology
      unless @topology
        @toplogy = Nodule::Topology.new(:auto => self)
      end

      # automatically determine a prefix for console output based on the key name known to the topology
      if name = @topology.key(self)
        @console_prefix = "[#{name}]: "
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
    #
    def add_reader(action=nil, &block)
      if block_given?
        @readers << block
      end

      if action.respond_to? :call
        @readers << action
      elsif action == :capture
        @readers << proc { |item| @output.push(item) }
      elsif action == :drain and @readers.empty?
        @readers << proc { |item| item } # make sure there's at least one proc so recvmsg gets run
      elsif action == :stderr
        @readers << @to_console
      elsif action == :ignore or action.nil?
        # nothing to do here
      # if it's an unrecognized symbol, defer resolution against the containing topology
      elsif action.kind_of? Symbol
        @readers << proc { |item| @topology[action].run_readers(item) }
      else
        raise ArgumentError.new "Invalid add_reader class: #{action.class}"
      end
    end

    def synchronize(&block)
      @@mutex.synchronize(&block)
    end
 
    def run_readers(item)
      @rmutex.synchronize do
        @readers.each do |reader|
          out = reader.call(item)
          @reader_out.push out if @want_reader_output
        end
      end
    end

    def run_writers
      @wmutex.synchronize do
        @writers.each do |writer|
          out = writer.call(item)
          @writer_out.push out if @want_writer_output
          yield out
        end
      end
    end
  end
end

require 'nodule/version'

module Nodule
  @sequence = 0
  def self.next_seq
    @sequence += 1
  end

  class Actor
    attr_reader :readers, :writers, :input, :output, :running
    @mutex = Mutex.new

    def initialize(opts={})
      @readers ||= []
      @writers ||= []
      @input   ||= []
      @output  ||= []
      @done    = false

      @want_reader_output = opts[:capture_readers]
      @want_writer_output = opts[:capture_writers]

      add_reader(opts[:reader]) if opts[:reader]
      if opts[:readers].respond_to? :each
        opts[:readers].each { |a| add_action(@readers, a) }
      end

      add_writer(opts[:writer]) if opts[:writer]
      if opts[:writers].respond_to? :each
        opts[:writers].each { |a| add_action(@writers, a) }
      end
    end

    def run
      @done = false
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

    def wait
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
        @readers << proc do |item|
          if item.to_s.respond_to? :color
            STDERR.puts item.to_s.color(:cyan)
          else
            STDERR.puts item.to_s
          end
        end
      elsif action == :ignore or action.nil?
        # nothing to do here
      else
        raise ArgumentError.new "Invalid add_reader class: #{action.class}"
      end
    end

    def synchronize(&block)
      @mutex.synchronize &block
    end
 
    def run_readers(item)
      synchronize do
        @readers.each do |reader|
          out = reader.call(item)
          @reader_out.push out if @want_reader_output
        end
      end
    end

    def run_writers
      synchronize do
        @writers.each do |writer|
          out = writer.call(item)
          @writer_out.push out if @want_writer_output
          yield out
        end
      end
    end
  end
end

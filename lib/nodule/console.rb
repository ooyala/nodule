require 'nodule/actor'
require 'rainbow'

module Nodule
  #
  # a simple colored output resource
  #
  # e.g. Nodule::Console.new(:fg => :green)
  # Nodule::Console.new(:fg => :green, :bg => :white)
  #
  class Console < Actor
    #
    # Create a new console actor.
    # Color values must be valid for rainbow. See its documentation.
    # @param [Hash] opts
    # @option [Symbol] opts :fg the foreground color symbol or RGB value
    # @option [Symbol] opts :bg the background color symbol or RGB value
    #
    def initialize(opts={})
      super(opts)

      if opts[:fg] and opts[:bg]
        add_reader { |line,actor| display actor, line.to_s.foreground(opts[:fg]).background(opts[:bg]) }
      elsif opts[:fg]
        add_reader { |line,actor| display actor, line.to_s.foreground(opts[:fg]) }
      elsif opts[:bg]
        add_reader { |line,actor| display actor, line.to_s.background(opts[:bg]) }
      else
        add_reader { |line,actor| display actor, line.to_s }
      end
    end

    private

    #
    # Write to stdout using puts, but append a prefix if it's defined.
    # @param [Object] actor if this responds to :prefix, :prefix will be prepended to the output
    # @param [String] line the data to write to stdout
    #
    def display(actor, line)
      if actor.respond_to? :prefix
        puts "#{actor.prefix}#{line}"
      else
        puts line
      end
    end

  end
end

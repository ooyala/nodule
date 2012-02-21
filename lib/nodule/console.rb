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
    def initialize(opts={})
      super(opts)

      if opts[:fg] and opts[:bg]
        add_reader { |line| puts line.to_s.foreground(opts[:fg]).background(opts[:bg]) }
      elsif opts[:fg]
        add_reader { |line| puts line.to_s.foreground(opts[:fg]) }
      elsif opts[:bg]
        add_reader { |line| puts line.to_s.background(opts[:bg]) }
      else
        add_reader { |line| puts line.to_s }
      end
    end
  end
end

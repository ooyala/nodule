require 'nodule/actor'

module Nodule
  class Tempfile < Actor
    PREFIX = 'nodule-'
    attr_reader :file

    def initialize(opts={})
      suffix = opts[:suffix] || ''
      @file = "#{PREFIX}#{::Process.pid}-#{Nodule.next_seq}#{suffix}"
      super(opts)
    end

    def stop
      File.unlink(@file) if File.exists?(@file)
      super
    end

    def to_s
      @file
    end
  end
end


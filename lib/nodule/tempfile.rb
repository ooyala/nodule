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
      # Ruby caches stat_t somewhere and causes race conditions, but we don't really
      # care here as long as the file is gone.
      begin
        File.unlink(@file)
      rescue Errno::ENOENT
      end

      super
    end

    def to_s
      @file
    end
  end
end


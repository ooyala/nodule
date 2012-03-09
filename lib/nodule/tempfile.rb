require 'nodule/actor'
require 'fileutils'

module Nodule
  class Tempfile < Actor
    PREFIX = 'nodule-'
    attr_reader :file

    def initialize(opts={})
      suffix = opts[:suffix] || ''
      @file = "#{PREFIX}#{::Process.pid}-#{Nodule.next_seq}#{suffix}"

      if opts[:directory]
        @is_dir = true
        if opts[:directory].kind_of? String
          FileUtils.mkdir_p File.join(opts[:directory], @file)
        else
          FileUtils.mkdir @file
        end
      else
        @is_dir = false
      end

      @cleanup = opts.has_key?(:cleanup) ? opts[:cleanup] : true

      super(opts)
    end

    def stop
      if @cleanup
        # Ruby caches stat_t somewhere and causes race conditions, but we don't really
        # care here as long as the file is gone.
        begin
          FileUtils.rm_r(@file) if @is_dir
          File.unlink(@file)
        rescue Errno::ENOENT
        end
      end

      super
    end

    def to_s
      @file
    end
  end
end


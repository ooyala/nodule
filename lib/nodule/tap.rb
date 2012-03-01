require 'nodule/actor'

module Nodule
  class Tap < Actor
    def initialize
      @thread = nil
      @running = false
      super
    end

    def forward?
      false
    end

    #
    # Run the tap "device" in a thread.
    #
    def run
      @running = true
      return unless forward?

      @thread = Thread.new do
        Thread.current.abort_on_exception
        tap
      end

      super
    end

    def stop
      @running = false
      @thread.join if @thread
      super
    end
  end
end

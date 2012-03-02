require 'nodule/actor'

# This is just a stub at the moment. The intent is to provide
# infrastructure for tapping pipe-ish things for running tests
# via blocks. By pipe-ish, I mean ZeroMQ and UDP. Maybre TCP
# but deciding what constitutes the right amount of data to call
# the proc is tricky.

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

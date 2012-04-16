# Import alarm() from libc.

require 'nodule/base'
require 'ffi'

module Nodule
  module PosixAlarmImport
    extend FFI::Library
    ffi_lib FFI::Library::LIBC
    # unistd.h: unsigned alarm(unsigned seconds);
    attach_function :alarm, [ :uint ], :uint
  end

  class Alarm < Base
    def initialize(opts={})
      if opts[:timeout]
        PosixAlarmImport.alarm(opts[:timeout])
      end

      Signal.trap("ALRM") { abort "Got SIGALRM. Aborting."; }

      super(opts)
    end
  end
end

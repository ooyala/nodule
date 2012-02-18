Overview
--------

Nodule is an integration test harness that simplifies the setup and teardown of multi-process
or large multi-component applications.

When setting up complex tests with multiple processes, a lot of work ends up going into generating
configuration, command-line parameters, and other fiddly things that are their own sources
of annoying bugs. Nodule tries to tidy some of that up by providing a way to define a test
topology that automatically injects data in the right places lazily so it doesn't all have to
be done up-front.

Symbols
-------

In as many places as possible, Nodule allows you to use a symbol as a placeholder for a value,
which it will automatically resolve when it's needed and no earlier, so you aren't forced to worry
about ordering.

Saying ":file => Nodule::Tempfile.new" means that :file will resolve to a temporary file's path
(via .to_s) in any place it appears as a placeholder. :file can be used before it's associated with
a tempfile.

Procs
-----

In many places, procs can be used as placeholders and will be automatically called when needed.

Arrays
------

The process module requires commands to be specified as argv-style arrays. The array is scanned
for placeholders, which are converted as already described. The one addition is sub-arrays, which
are resolved and concatenated without padding. This is useful for parameters that use '=' without
spaces, for example, "dd if=<filename>" would be specified as ['dd', ['if=', :file]]. These sub-arrays
are resolved recursively, so multiple levels are allowed.

Example
-------

    #!/usr/bin/env ruby
    
    require "test/unit"
    require 'nodule/process'
    require 'nodule/topology'
    require 'nodule/tempfile'
    require 'nodule/console'
    
    class NoduleSimpleTest < Test::Unit::TestCase
      def setup
        @topo = Nodule::Topology.new(
          :greenio => Nodule::Console.new(:fg => :green),
          :redio   => Nodule::Console.new(:fg => :red),
          :file1   => Nodule::Tempfile.new(".html"),
          :wget    => Nodule::Process.new(
            '/usr/bin/wget', '-O', :file1, 'http://www.ooyala.com',
            :stdout => :greenio, :stderr => :redio
          )
        )
    
        @topo.run_serially
      end
    
      def teardown
        @topo.cleanup
      end
    
      def test_heartbeat
        filename = @topo[:file1].to_s
        assert File.exists? filename
      end
    end

Authors
-------

* Viet Nguyen
* Noah Gibbs
* Al Tobey

Dependencies
------------

* Ruby 1.9 (tested on 1.9.2p290)


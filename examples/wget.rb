#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require "test/unit"
require 'nodule/process'
require 'nodule/topology'
require 'nodule/tempfile'
require 'nodule/console'
require 'multi_json'

class NoduleSimpleTest < Test::Unit::TestCase
  def setup
    @topo = Nodule::Topology.new(
      :greenio      => Nodule::Console.new(:fg => :green),
      :redio        => Nodule::Console.new(:fg => :red),
      :file1        => Nodule::Tempfile.new(".html"),
    )

    # commands have to be in array form or process management is indeterminate
    @topo[:wget] = Nodule::Process.new(@topo,
      '/usr/bin/wget', '-O', :file1, 'http://www.ooyala.com',
      {:stdout => :greenio, :stderr => :redio}
    )

    @topo.start_all
  end

  def teardown
    @topo.cleanup
  end

  def test_heartbeat
    filename = @topo[:file1].to_s
    assert File.exists? filename
  end
end


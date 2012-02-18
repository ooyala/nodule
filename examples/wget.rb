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
      :greenio => Nodule::Console.new(:fg => :green),
      :redio   => Nodule::Console.new(:fg => :red),
      :file1   => Nodule::Tempfile.new(:suffix => ".html"),
      :wget    => Nodule::Process.new(
        '/usr/bin/wget', '-O', :file1, 'http://www.ooyala.com',
        :stdout => :greenio
      )
    )

    @topo.start_all
  end

  def teardown
    @topo.cleanup
  end

  def test_heartbeat
    @topo[:wget].wait
    filename = @topo[:file1].to_s
    assert File.exists? filename
  end
end


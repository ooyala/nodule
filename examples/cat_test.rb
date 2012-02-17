#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require "test/unit"
require 'nodule/process'
require 'nodule/topology'
require 'nodule/tempfile'
require 'nodule/console'
require 'rainbow'
require 'multi_json'

class NoduleDDCatTest < Test::Unit::TestCase
  BYTES=65536

  def setup
    @topo = Nodule::Topology.new(
      :greenio      => Nodule::Console.new(:fg => :green),
      :redio        => Nodule::Console.new(:fg => :red),
      :file1        => Nodule::Tempfile.new(".rand"),
      :file2        => Nodule::Tempfile.new(".copy"),
    )

    @topo[:dd] = Nodule::Process.new(@topo,
      '/bin/dd', 'if=/dev/urandom', ['of=', :file1], "bs=#{BYTES}", 'count=1',
      {:stdout => :greenio, :stderr => :redio}
    )

    @topo[:cat] = Nodule::Process.new(@topo,
      '/bin/cp', :file1, :file2,
      {:stdout => :greenio, :stderr => :redio}
    )

    @topo.run_serially
  end

  def teardown
    @topo.cleanup
  end

  def test_heartbeat
    file1 = @topo[:file1]
    file2 = @topo[:file2]

    assert_equal BYTES, File.new(file1.to_s).size
    assert_equal BYTES, File.new(file2.to_s).size
  end
end


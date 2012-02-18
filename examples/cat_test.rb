#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require "test/unit"
require 'nodule/process'
require 'nodule/topology'
require 'nodule/tempfile'
require 'nodule/console'

class NoduleDDCatTest < Test::Unit::TestCase
  BYTES=65536

  def setup
    @topo = Nodule::Topology.new(
      :redio   => Nodule::Console.new(:fg => :red),
      :greenio => Nodule::Console.new(:fg => :green),
      :file1   => Nodule::Tempfile.new(:suffix => ".rand"),
      :file2   => Nodule::Tempfile.new(:suffix => ".copy"),
      :dd      => Nodule::Process.new(
        '/bin/dd', 'if=/dev/urandom', ['of=', :file1], "bs=#{BYTES}", 'count=1',
        :stderr => :redio, :verbose => :greenio
      ),
      :ls      => Nodule::Process.new('ls', '-l', :stdout => :greenio),
      :copy    => Nodule::Process.new('/bin/cp', :file1, :file2, :stderr => :redio),
    )

    # start up and run in order
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


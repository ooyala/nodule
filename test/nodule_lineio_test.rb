#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require 'rubygems'
require 'minitest/autorun'
require 'nodule/line_io'

class NoduleLineIOTest < MiniTest::Unit::TestCase
  def setup
      @r_pipe, @w_pipe = IO.pipe
  end

  def test_stdio
    io = Nodule::LineIO.new :io => @r_pipe, :run => true, :reader => :capture

    @w_pipe.puts "x"
    io.require_read_count 1, 10
    assert_equal "x", io.output.first.chomp, "read data from pipe"

    assert_equal 1, io.read_count
    @w_pipe.puts "y"
    io.require_read_count 2, 10

    assert_equal 2, io.read_count
    io.clear!
    assert_equal 0, io.read_count
    @w_pipe.puts "y"

    io.require_read_count 1, 10
    assert_equal "y", io.output.first.chomp, "read data from pipe"
  end
end

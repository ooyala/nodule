#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require 'rubygems'
require 'minitest/autorun'
require 'nodule/stdio'

class NoduleStdioTest < MiniTest::Unit::TestCase
  def setup
      @stdin_r, @stdin    = IO.pipe
      @stdout,  @stdout_w = IO.pipe
      @stderr,  @stderr_w = IO.pipe
  end

  def test_stdio
    io = Nodule::Stdio.new(
      :stdin => @stdin,
      :stdout => @stdout,
      :stderr => @stderr
    )

    assert io.wait(0.01), "stdin should be ready, this should be instant"
    assert io.writable?(0.01), "stdin should be ready, this should be instant"
    refute io.readable?(0.01), "no data has been written to the pipe so this should return false"
    refute io.stdout?(0.01), "no data has been written to the pipe so this should return false"
    refute io.stderr?(0.01), "no data has been written to the pipe so this should return false"

    @stdout_w.puts "x"
    assert io.readable?(0.01), "no data has been written to the pipe so this should return false"
    assert io.stdout?(0.01), "no data has been written to the pipe so this should return false"
    refute io.stderr?(0.01), "no data has been written to the pipe so this should return false"
    assert_equal "x", io.output.first.chomp, "read data from pipe"

    @stderr_w.puts "y"
    assert io.readable?(0.01), "no data has been written to the pipe so this should return false"
    refute io.stdout?(0.01), "no data has been written to the pipe so this should return false"
    assert io.stderr?(0.01), "no data has been written to the pipe so this should return false"
    assert_equal "y", io.errors.first.chomp, "read data from pipe"

    io.puts "z"
    assert_equal "z", @stdin_r.readline.chomp

    assert io.wait(0.01), "wait should retun true before closing"
    refute io.done?, "done? false before close"

    io.close

    refute io.wait(0.01), "wait should retun false after closing"
    assert io.done?, "done? true after close"
  end
end

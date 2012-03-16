#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require 'rubygems'
require 'minitest/autorun'
require 'nodule/process'

class NoduleProcessTest < MiniTest::Unit::TestCase
  def test_process
    p = Nodule::Process.new("/bin/true", :run => true)
    assert p.done?, "true exits immediately, done? should be true"
  end
end

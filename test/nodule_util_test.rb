#!/usr/bin/env ruby

require_relative 'helper'
require 'minitest/autorun'
require 'nodule/util'

class NoduleUtilTest < MiniTest::Unit::TestCase
  def test_random_tcp_port
    port = nil
    assert_block do
      port = Nodule::Util.random_tcp_port
    end
    assert_kind_of Fixnum, port
    assert port > 1024
    assert port < 65536
  end

  def test_random_udp_port
    port = nil
    assert_block do
      port = Nodule::Util.random_udp_port
    end
    assert_kind_of Fixnum, port
    assert port > 1024
    assert port < 65536
  end
end

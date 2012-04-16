#!/usr/bin/env ruby

require_relative 'helper'
require 'minitest/autorun'
require 'nodule/util'

class NoduleUtilTest < MiniTest::Unit::TestCase
  def test_random_tcp_port
    port = nil
    assert (port = Nodule::Util.random_tcp_port),
      "Can't create Nodule::Util with random TCP port!"
    assert_kind_of Fixnum, port
    assert port > 1024
    assert port < 65536
  end

  def test_random_udp_port
    port = nil
    assert (port = Nodule::Util.random_udp_port),
      "Can't create Nodule::Util with random UDP port!"
    assert_kind_of Fixnum, port
    assert port > 1024
    assert port < 65536
  end
end

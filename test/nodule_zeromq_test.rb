#!/usr/bin/env ruby
$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require 'rubygems'
require 'minitest/autorun'
require 'nodule/zeromq'

class NoduleZeromqTest < MiniTest::Unit::TestCase
  def test_zeromq_setup
    t1 = Nodule::ZeroMQ.new(:uri => :gen)
    refute_nil t1
    t2 = Nodule::ZeroMQ.new(:uri => :gen, :bind => ZMQ::PUSH)
    refute_nil t2
    t3 = Nodule::ZeroMQ.new(:uri => t2.uri, :connect => ZMQ::PULL)
    refute_nil t3
  end

  def test_zeromq_pubsub
    pub = Nodule::ZeroMQ.new(:uri => :gen, :bind => ZMQ::PUB)
    refute_nil pub
    sub = Nodule::ZeroMQ.new(:uri => pub.uri, :connect => ZMQ::SUB, :reader => :capture)
    refute_nil sub
    pub.run
    refute pub.done?
    sub.run
    refute sub.done?

    pub.socket.send_string "Hello Verld!"
    5.times do
      if sub.output.count > 0
        assert_equal "Hello Verld!", sub.output.flatten[0]
        break
      end
      sleep 0.1
    end
  end
end

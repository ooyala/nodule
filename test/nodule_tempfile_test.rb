#!/usr/bin/env ruby

require_relative 'helper'
require 'minitest/autorun'
require 'nodule/tempfile'

class NoduleTempfileTest < MiniTest::Unit::TestCase
  def test_basic
    tfile = nil
    assert_block do
      tfile = Nodule::Tempfile.new
    end

    assert_kind_of Nodule::Tempfile, tfile
    assert_kind_of Nodule::Base, tfile

    assert_block do
      tfile = Nodule::Tempfile.new(:directory => true)
    end
    assert_kind_of Nodule::Tempfile, tfile
    assert_kind_of Nodule::Base, tfile

    tfile.stop
  end
end

#!/usr/bin/env ruby

require_relative 'helper'
require 'minitest/autorun'
require 'nodule/tempfile'

class NoduleTempfileTest < MiniTest::Unit::TestCase
  def test_basic
    tfile = nil
    assert (tfile = Nodule::Tempfile.new), "Can't create Nodule::Tempfile!"

    assert_kind_of Nodule::Tempfile, tfile
    assert_kind_of Nodule::Base, tfile

    assert (tfile = Nodule::Tempfile.new(:directory => true)),
      "Can't create Nodule::Tempfile on a directory!"
    assert_kind_of Nodule::Tempfile, tfile
    assert_kind_of Nodule::Base, tfile

    tfile.stop
  end
end

#!/usr/bin/env ruby

require_relative 'helper'
require 'minitest/autorun'
require 'nodule/cassandra'

class NoduleCassandraTest < MiniTest::Unit::TestCase
  KEYSPACE = "NoduleTest"

  def test_cassandra
    cass = nil
    assert_block do
      cass = Nodule::Cassandra.new :keyspace => KEYSPACE
    end

    cass.run
    cass.create_keyspace

    assert_nil cass.waitpid

    assert_kind_of Cassandra, cass.client

    cfdef = CassandraThrift::CfDef.new :name => "foo", :keyspace => KEYSPACE
    refute_nil cass.client.add_column_family cfdef

    assert File.directory?(File.join(cass.data, KEYSPACE))

    cass.stop

    assert File.directory?(cass.tmp) != true
  end
end

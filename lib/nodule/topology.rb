#!/usr/bin/env ruby

# To test, you'll be creating a Topology, representing a cluster of
# interconnected processes.  You'll also optionally declare a number
# of resources for the test framework to verify - files it can read,
# network connections it can snoop or spoof and so on.  By declaring
# these resources, you gain the ability to make assertions against
# them.

# After creating the Topology and adding processes to it, you run it.
# When you do, the framework will allocate resources and rework the
# command line of every node to use the resources that the framework
# has allocated, faked or mocked.  For instance, for a ZeroMQ socket
# the framework will create an identical forwarding socket that
# records traffic before resending to the application's actual socket.

# Since the test framework doesn't know the command line of every
# possible executable, you'll need to write your command lines in
# terms of those resources.  Erb is used to let you do logic in the
# command-line declarations, and variables are passed in for the
# resources that the test framework has created.

#
# Module to help build a topology on a single machine. All pieces of the topology
# that run in subprocesses will be referenceable through this wrapper.
#
module Nodule
  class TopologyProcessStillRunningError < StandardError; end
  class TopologyIntegrationRequiredError < StandardError; end

  class Topology
    def initialize(opts={})
      @resources = {}
      @started = {}

      opts.each do |name,value|
        inject_topology(name, value)
        @resources[name] = value
      end

      @all_stopped = true
    end

    def inject_topology(name, value)
      unless value.respond_to? :join_topology!
        raise TopologyIntegrationRequiredError.new "#{name} => #{value} does not respond to :join_topology!"
      end
      value.join_topology! self
    end

    def [](key)
      @resources[key]
    end

    def []=(key, value)
      inject_topology(key, value)
      @resources[key] = value
    end

    def has_key?(key)
      @resources.has_key?(key)
    end

    def keys
      @resources.keys
    end

    def key(object)
      @resources.key(object)
    end

    def to_hash
      @resources
    end

    def start_all
      @resources.keys.each do |key|
        start key unless @started[key]
      end

      # If we do many cycles, this will wind up getting called repeatedly.
      # The @all_stopped variable will make sure that's a really fast
      # operation.
      at_exit { stop_all }
    end

    #
    # Run each process in order, waiting for each one to complete & return before
    # running the next.
    #
    # Resources are all started up at once.
    #
    def run_serially
      @all_stopped = false

      @resources.each do |name,object|
        object.run
        if object.respond_to? :wait
          object.wait
        else
          object.stop
        end
      end

      @all_stopped = true
    end

    #
    # Starts the node in the topology. Looks up the node's command
    # given that the topology hash is keyed off of the node's name.
    #
    def start name
      @all_stopped = false

      # run the command that starts up the node and store the subprocess for later manipulation
      @resources[name].run

      @started[name] = true
    end

    #
    # Immediately kills a node given its topology name
    #
    def stop name
      object = @resources[name]
      object.stop
      object.wait 1 unless object.done?
      object.stop!  unless object.done?
      object.wait 1 unless object.done?
      unless object.done?
        raise "Could not stop resource: #{object.class} #{object.inspect}"
      end

      @started[name] = false
    end

    #
    # Kills all of the nodes in the topology.
    #
    def stop_all
      @resources.each { |name,object| stop name unless object.done? } unless @all_stopped
    end

    def started?(key)
      @started[key.to_sym] == true
    end

    def start_all_but(*resources)
      @resources.keys.each do |key|
        if !@started[key] && !resources.flatten.map(&:to_sym).include?(key)
          start key
        end
      end

      at_exit { stop_all_but resources }
    end

    def stop_all_but(*resources)
      @resources.each do |name,object|
        if !resources.flatten.map(&:to_sym).include?(name.to_sym) && !object.done?
          stop name
        end
      end unless @all_stopped
    end

    def cleanup
      @resources.each { |_,object| object.stop }
    end

    def wait(name, timeout=60)
      @resources[name].wait timeout
    end

    #
    # Wait for all resources to exit normally.
    #
    def wait_all
      @resources.each do |name,object|
        object.wait if object.respond_to? :wait
      end
    end

    #
    # Reset all processes for restart.
    #
    def reset_all
      raise TopologyProcessStillRunningError.new unless @all_stopped
      @resources.each { |_, object| object.reset }
    end

  end
end

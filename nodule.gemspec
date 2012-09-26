# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "nodule/version"

Gem::Specification.new do |s|
  s.name        = "nodule"
  s.version     = Nodule::VERSION
  s.authors     = ["Al Tobey", "Noah Gibbs", "Viet Nguyen", "Jay Bhat"]
  s.email       = ["al@ooyala.com", "noah@ooyala.com", "viet@ooyala.com", "bhat@ooyala.com"]
  s.homepage    = ""
  s.summary     = %q{Nodule starts, stops, tests and redirects groups of processes}
  s.description = %q{Nodule lets you declare Topologies of processes, which can be started or stopped together.  You can also redirect sockets, set up interprocess communication, make assertions on captured packets between processes and generally monitor or change the interaction of any of your processes.  Nodule is great for integration testing or for bringing up complicated interdependent sets of processes on a single host.}

  s.rubyforge_project = "nodule"
  s.required_ruby_version = ">= 1.9.2"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  # specify any dependencies here; for example:
  s.add_development_dependency "minitest"
  # s.add_runtime_dependency "rest-client"
  s.add_runtime_dependency "ffi-rzmq"
  s.add_runtime_dependency "cassandra", "~>0.15"
  s.add_runtime_dependency "rainbow"
end

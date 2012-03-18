require "bundler/gem_tasks"
require "rake/testtask"

namespace "test" do
  desc "Unit tests"
  Rake::TestTask.new(:units) do |t|
    t.libs += ["test"]  # require from test subdir
    t.test_files = Dir["test/nodule_*_test.rb"]
    t.verbose = true
  end
end

task :test => ["test:units"] do
  puts "All tests completed..."
end

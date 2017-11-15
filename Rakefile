require 'bundler/gem_tasks'
require 'rake/testtask'

require 'bump/tasks'
require 'wwtd/tasks'

Rake::TestTask.new(:unit_tests) do |test|
  test.libs << 'lib' << 'test'
  test.pattern = 'test/*_test.rb'
  test.verbose = true
end

task :integration_tests do
  retval = true
  Dir.glob(__dir__ + '/test/integration/*_test.rb').each do |f|
    retval &= system("ruby #{f}")
  end
  exit retval
end

task test: [:unit_tests, :integration_tests]

task :default => 'wwtd:local'

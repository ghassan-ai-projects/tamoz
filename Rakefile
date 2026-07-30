# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

namespace :design do
  desc "Validate the authoritative design package"
  task :validate do
    ruby "docs/design-v0.1/validate_design.rb"
  end
end

namespace :fixtures do
  desc "Regenerate canonical M0 evaluation fixtures"
  task :refresh do
    ruby "script/generate_m0_fixtures"
  end
end

desc "Run every M0 quality gate"
task ci: ["design:validate", :test]

task default: :ci

# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"

RUBY_SOURCES = FileList[
  "Rakefile",
  "bin/*",
  "script/*",
  "gems/**/*.rb",
  "gems/**/exe/*",
  "test/**/*.rb"
].select { |path| File.file?(path) }.freeze

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.warning = true
end

desc "Check every Ruby source file for syntax errors"
task :syntax do
  failures = RUBY_SOURCES.reject do |path|
    system(RbConfig.ruby, "-wc", path, out: File::NULL, err: File::NULL)
  end
  abort("Ruby syntax failed: #{failures.join(", ")}") unless failures.empty?
end

namespace :design do
  desc "Validate the authoritative design package"
  task :validate do
    ruby "docs/design-v0.1/validate_design.rb"
  end
end

namespace :fixtures do
  desc "Regenerate canonical evaluation fixtures"
  task :refresh do
    ruby "script/generate_m0_fixtures"
    ruby "script/generate_m1_fixtures"
    ruby "script/generate_m2_fixtures"
    ruby "script/generate_agent_smoke_fixtures"
  end
end

desc "Run every implemented milestone quality gate"
task ci: ["design:validate", :syntax, :test]

task default: :ci

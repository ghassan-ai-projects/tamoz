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

# The autonomy scorecard is a MILESTONE gate, not a regression gate: its cases
# describe the product Tamoz is being built into and fail until that product
# exists. Keeping it out of `rake test` lets `rake ci` keep its meaning — no
# regression in what already works — while `rake autonomy` reports honestly on
# what does not work yet. Both must pass to close the milestone.
AUTONOMY_TESTS = ["test/autonomy_scorecard_test.rb"].freeze

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.test_files = FileList["test/**/*_test.rb"].reject { |path| AUTONOMY_TESTS.include?(path) }
  task.warning = true
end

desc "Run the autonomy scorecard and regenerate docs/autonomy-scorecard.json"
task :autonomy do
  ruby "script/autonomy_scorecard"
end

desc "The autonomy milestone gate: every scorecard case must pass"
task :autonomy_strict do
  ruby "script/autonomy_scorecard --strict"
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
    ruby "script/generate_agent_memory_fixtures"
  end
end

desc "Run every implemented milestone quality gate"
task ci: ["design:validate", :syntax, :test]

task default: :ci

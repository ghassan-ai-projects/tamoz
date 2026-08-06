# frozen_string_literal: true

# Q0-4 (docs/QUALITY_PROGRAM.md): SimpleCov with branch coverage, gated behind
# RUN_COVERAGE=1 so the everyday gate stays fast. Loaded first in test_helper,
# before any tamoz code loads, so instrumentation covers production code.
#
# Production files only: track_files confines the measurement to gems/*/lib;
# the test filter keeps test/ out of both the measured set and the report.
require 'simplecov'

SIMPLE_COV_ROOT = File.expand_path('../..', __dir__)

SimpleCov.start do
  enable_coverage :branch
  command_name ENV.fetch('SIMPLE_COV_COMMAND_NAME', 'tests:main')
  track_files "#{SIMPLE_COV_ROOT}/gems/*/lib/**/*.rb"
  add_filter '/test/'
end

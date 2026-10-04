# frozen_string_literal: true

require 'simplecov'

SIMPLE_COV_ROOT = File.expand_path('../..', __dir__)

SimpleCov.start do
  enable_coverage :branch
  command_name ENV.fetch('SIMPLE_COV_COMMAND_NAME', 'tests:main')
  track_files "#{SIMPLE_COV_ROOT}/gems/*/lib/**/*.rb"
  add_filter '/test/'
end

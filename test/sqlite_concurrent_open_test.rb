# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

# The gateway and the worker are started together on a fresh runtime directory.
class SQLiteConcurrentOpenTest < Minitest::Test
  def test_processes_opening_a_fresh_database_together_all_succeed
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      errors = Queue.new
      threads = Array.new(4) do
        Thread.new do
          Tamoz::SQLite::Adapter.new(path:).close
        rescue StandardError => e
          errors << e
        end
      end
      threads.each(&:join)
      failures = Array.new(errors.size) { errors.pop }.map { |error| "#{error.class}: #{error.message}" }

      assert_empty failures
    end
  end
end

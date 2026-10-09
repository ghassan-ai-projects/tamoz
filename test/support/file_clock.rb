# frozen_string_literal: true

require 'minitest'

module TestSuite
  # Sums the run time of the tests each file defines and fails the run naming every file over the cap.
  module FileClock
    CAP_ENV = 'TEST_FILE_CAP_SECONDS'

    module_function

    def require_files(paths)
      owners = {}
      paths.each do |path|
        known = Minitest::Runnable.runnables.dup
        require File.expand_path(path)
        (Minitest::Runnable.runnables - known).each { |runnable| owners[runnable.name] = path }
      end
      cap = ENV.fetch(CAP_ENV, '')
      return if cap.empty?

      @reporter = Reporter.new(cap: Float(cap), owners:)
      Minitest.register_plugin(self)
    end

    def minitest_plugin_init(_options)
      Minitest.reporter << @reporter
    end

    class Reporter < Minitest::AbstractReporter
      def initialize(cap:, owners:, io: $stdout)
        super()
        @cap = cap
        @owners = owners
        @io = io
        @seconds = Hash.new(0.0)
      end

      def record(result)
        @seconds[@owners.fetch(result.klass, result.klass.to_s)] += result.time
      end

      def passed?
        offenders.empty?
      end

      def report
        offenders.each do |path, seconds|
          @io.puts format('TEST FILE OVER CAP: %<path>s took %<seconds>.1fs (cap %<cap>.1fs)', path:, seconds:, cap: @cap)
        end
      end

      def offenders
        @seconds.select { |_, seconds| seconds > @cap }.sort_by { |_, seconds| -seconds }
      end
    end
  end
end

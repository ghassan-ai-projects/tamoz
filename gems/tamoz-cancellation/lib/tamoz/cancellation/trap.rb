# frozen_string_literal: true

module Tamoz
  module Cancellation
    # INT/TERM trap installation that cannot deadlock or lose a stop request:
    # the handler ALWAYS defers to a fresh thread because Mutex#synchronize
    # raises ThreadError in trap context — doing real work inline turns a
    # supervisor's SIGTERM into a dead backtrace instead of a stopped loop.
    # Prior handlers are restored on exit so this is safe to nest in-process
    # (tests, embedding).
    class Trap
      EXIT_CODES = { "sigint" => 130, "sigterm" => 143 }.freeze

      SIGNALS = { "INT" => "sigint", "TERM" => "sigterm" }.freeze

      class << self
        # Installs both traps; each handler receives its canonical signal name
        # ("sigint" / "sigterm"); the block is the guarded body. `int:` and
        # `term:` are the handler callables for their signal.
        def install(int:, term:)
          raise ArgumentError, "a guarded body is required" unless block_given?

          previous = {}
          begin
            { "INT" => int, "TERM" => term }.each do |signal, handler|
              previous[signal] = Signal.trap(signal) do
                Thread.new { handler.call(SIGNALS.fetch(signal)) }
              end
            end
            yield
          ensure
            previous.each { |signal, handler| Signal.trap(signal, handler) if handler }
          end
        end
      end
    end
  end
end

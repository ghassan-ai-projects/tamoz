# frozen_string_literal: true

module Tamoz
  module Stream
    # P14-S (plan §8/C5) — the replay runtime.
    #
    # Credential isolation is structural: the replay runtime constructor
    # accepts NO credential argument (type-level, asserted by the API shape),
    # and the four replay modes resolve NO credentials (behavioral, asserted by
    # the poison-resolver test):
    #
    # - :deterministic        — resolve NO credentials.
    # - :recorded_cognition   — resolve NO credentials (replay recorded
    #   cognition output, no model call).
    # - :shadow               — run a candidate model via a fixture/reference
    #   model; resolve NO effector or source credentials.
    # - :counterfactual       — route commands to the simulator only; resolve
    #   no production credentials.
    #
    # Enabling the simulator never enables a real effector.
    class ReplayRuntime
      MODES = %i[deterministic recorded_cognition shadow counterfactual].freeze

      def initialize(mode:, fixture_model: nil, simulator: nil)
        unless MODES.include?(mode)
          raise Tamoz::ConfigurationError, "replay mode must be one of #{MODES.inspect}"
        end
        @mode = mode
        @fixture_model = fixture_model
        @simulator = simulator
      end

      attr_reader :mode

      # The credential resolver is deliberately ABSENT from this class. A
      # poison resolver that raises on ANY resolution must never be called by
      # any replay mode (C5 behavioral test). Replay runs the deterministic
      # operator chain; cognition in `shadow` uses the injected fixture model.
      def run(process:, clock:, batch:)
        process.call(batch, clock)
      end

      # The simulator is the ONLY effector, and only in :counterfactual mode
      # does a command route to it (still simulator-only, no production
      # credentials).
      def deliver_command(command)
        raise StreamError, "no simulator is configured" unless @simulator
        raise StreamError, "commands only route in counterfactual mode" unless @mode == :counterfactual

        @simulator.accept(command)
      end
    end
  end
end

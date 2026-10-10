# frozen_string_literal: true

module Tamoz
  module Comms
    # The turn an admitted update enqueues: its thread and profile, the terminal capacity reserved for its
    # answer (invariant 57), and what rides in its payload — the conversation so far, a deep-research input,
    # and an attachment's kind, digest and labels (read by the worker, never by the gateway).
    Turn = Data.define(:thread, :profile_id, :reservation, :history, :research, :attachment) do
      def initialize(history: [], research: nil, attachment: nil,
                     **required)
        super
      end

      def wire = to_h.transform_keys(&:to_s)
    end
  end
end

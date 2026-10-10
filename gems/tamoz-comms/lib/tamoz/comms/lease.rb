# frozen_string_literal: true

module Tamoz
  module Comms
    # Who holds a fenced store lease — a poller's stream or a drainer's delivery claim. A write under a
    # lease matches both, so a stale holder changes nothing.
    Lease = Data.define(:owner, :fence) do
      def wire = to_h.transform_keys(&:to_s)
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Observability
    # The seeded, closed registry (design §6.1, §8): every name an existing
    # accepted design has already published — the worker's request lifecycle,
    # the comms evidence events (COMMS_DESIGN §16), and the model/tool events
    # (M4_PLAN §13, minus TTFT, which a non-streaming model path cannot
    # measure). Producers emit names; this catalog is the contract.
    module Catalog
      def self.fetch(name) = CATALOG.fetch(name)
      def self.registered?(name) = CATALOG.registered?(name)
      def self.names = CATALOG.names
      def self.entries = CATALOG.entries
      def self.validate_signal(signal) = CATALOG.validate_signal(signal)
      def self.safety_bearing?(name) = CATALOG.safety_bearing?(name)

      CATALOG = SignalCatalog.new.tap do |catalog|
        [ModelSignals, WorkerSignals, CommsSignals, Measurements].each { |family| family.seed(catalog) }
      end.freeze

      private_constant :ModelSignals, :WorkerSignals, :CommsSignals, :Measurements
    end
  end
end

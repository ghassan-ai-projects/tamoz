# frozen_string_literal: true

module Tamoz
  module Observability
    module Exporter
      def open(_descriptor, _credential = nil) = raise NotImplementedError
      def export(_batch, deadline_ms:) = raise NotImplementedError
      def close(deadline_ms:) = raise NotImplementedError
    end
  end
end

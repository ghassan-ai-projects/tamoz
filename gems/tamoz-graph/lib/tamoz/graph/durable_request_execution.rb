# frozen_string_literal: true

module Tamoz
  module Graph
    # Immutable inputs for one claimed durable-request execution.
    DurableRequestExecution = Data.define(:request, :writer, :concurrency, :context)
  end
end

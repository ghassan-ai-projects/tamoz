# frozen_string_literal: true

require 'tamoz/core'
require 'tamoz/concurrency'
require_relative 'observability/version'
require_relative 'observability/errors'
require_relative 'observability/signal_catalog'
require_relative 'observability/correlation'
require_relative 'observability/signal'
require_relative 'observability/recorder'
require_relative 'observability/recorder_drop_ledger'
require_relative 'observability/recorder_journal'
require_relative 'observability/catalog'
require_relative 'observability/content_policy'
require_relative 'observability/recorders'
require_relative 'observability/producer'
require_relative 'observability/metrics'
require_relative 'observability/telemetry_reader'
require_relative 'observability/trace'
require_relative 'observability/exporter'
require_relative 'observability/usage'
require_relative 'observability/model_call'
require_relative 'observability/notifier'

module Tamoz
  # The observability signal plane: a closed, versioned signal catalog,
  # correlation identity derived from durable state, one immutable Signal
  # value, and the Recorder contract every producer talks to. Depends only
  # on tamoz-core, and signals must never change a committed byte.
  module Observability
    SCHEMA_VERSION = 1
  end
end

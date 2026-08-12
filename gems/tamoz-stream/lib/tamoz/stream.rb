# frozen_string_literal: true

require "tamoz/core"
require_relative "stream/version"
require_relative "stream/errors"
require_relative "stream/capability_host"
require_relative "stream/situation_snapshot"
require_relative "stream/situation_request"
require_relative "stream/approval_relay"
require_relative "stream/outcome_subscriber"
require_relative "stream/situation_memory"
require_relative "stream/worker_server"

module Tamoz
  # T8.3 (PLAN_TAMOZ_STREAM_BUILD T8.3) — the supervised episode worker.
  # The P14 streaming-input engine (channels, events, partitions, connectors,
  # cognition admission, replay) was retired by forward migration; this gem is
  # now ONE responsibility: run a supervised non-interactive episode against
  # a verified Situation snapshot, propose typed Decisions, and bridge the
  # stream's reverse channel (evidence, outcomes, approvals) — all inside the
  # containment host.
  module Stream
  end
end

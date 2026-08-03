# frozen_string_literal: true

require "tamoz/core"
require_relative "stream/version"
require_relative "stream/errors"
require_relative "stream/patterns"
require_relative "stream/stream_clock"
require_relative "stream/clock"
require_relative "stream/channel_descriptor"
require_relative "stream/event_envelope"
require_relative "stream/situation_spec"
require_relative "stream/cognition_admission"
require_relative "stream/action_boundary"
require_relative "stream/replay_runtime"
require_relative "stream/connector"
require_relative "stream/stream_store"

module Tamoz
  # P14 — streaming input and simulated physical-world assistance
  # (STREAMING_INPUT_DESIGN, invariants 44–51).
  #
  # ONE responsibility: convert an authenticated read-only source into
  # deterministic immutable Situations, propose typed intents, and deliver
  # commands to a SIMULATOR ONLY through current-state policy and an
  # independently controlled interlock. No real physical actuator is
  # connected without explicit owner approval (owner constraint, binding).
  #
  # Plane ownership (design §3): only the cognition plane starts a tamoz-graph
  # run or loads a model; connector polling, stream operators, Situation
  # reduction, and action reconciliation never make model calls.
  module Stream
  end
end

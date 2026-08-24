# frozen_string_literal: true

# The deliberation substrate: records, receipts, the plan/review/execute/
# verify engine, and the effect seam. Required by tamoz-agent ahead of every
# vertical; nothing here reaches back up into session, worker, or CLI code.
require "tamoz/core"
require "tamoz/tools"

require_relative "agent/kernel/version"
require_relative "agent/errors"
require_relative "agent/event"
require_relative "agent/graph_versions"
require_relative "agent/request_projection"
require_relative "agent/request_route"
require_relative "agent/diagnosis_catalog"
require_relative "agent/intent_catalog"
require_relative "agent/skill_set"
require_relative "agent/model_receipt"
require_relative "agent/reasoning_document"
require_relative "agent/providers"
require_relative "agent/episode_model_transport"
require_relative "agent/episode_model_call"
require_relative "agent/episode_tool_call"
require_relative "agent/receipt_budget_controller"
require_relative "agent/witness_gateway"
require_relative "agent/witness_verifier"
require_relative "agent/sealed_build"
require_relative "agent/episode_frame_builder"
require_relative "agent/episode_nodes"
require_relative "agent/behavior_version"
require_relative "agent/plan"
require_relative "agent/deliberation"
require_relative "agent/effect_dispatcher"

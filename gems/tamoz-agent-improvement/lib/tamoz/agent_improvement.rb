# frozen_string_literal: true

# Bounded self-improvement: candidate provenance, one heuristic generated from
# verified trajectories, paired evaluation, human-gated promotion/rollback.
# Nothing here reaches up into session, worker, or CLI code.
require "tamoz/agent_kernel"
require "tamoz/agent_memory"

require_relative "agent/improvement/version"
require_relative "agent/improvement/errors"
require_relative "agent/improvement/provenance"
require_relative "agent/improvement/heuristic"
require_relative "agent/improvement/generator"
require_relative "agent/improvement/evaluation_report"
require_relative "agent/improvement/monitor"
require_relative "agent/improvement/promotion"
require_relative "agent/improvement/candidate_proposal"
require_relative "agent/improvement/candidate_policy"
require_relative "agent/improvement/candidate_lifecycle"

module Tamoz
  module Agent
    module Improvement
    end
  end
end

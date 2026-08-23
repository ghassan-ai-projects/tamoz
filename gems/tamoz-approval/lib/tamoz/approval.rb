# frozen_string_literal: true

require 'tamoz/core'
require_relative 'approval/version'
require_relative 'approval/errors'
require_relative 'approval/request'
require_relative 'approval/decision'
require_relative 'approval/canonical'
require_relative 'approval/grant'
require_relative 'approval/answer'
require_relative 'approval/evaluator'
require_relative 'approval/policy_document'
require_relative 'approval/grant_store'
require_relative 'approval/decision_log'
require_relative 'approval/engine'

module Tamoz
  # Approval/permission policy: one component that decides whether a tool call
  # needs approval, reading digest-pinned YAML policy data.
  module Approval
    # The policy data this gem ships (base + profiles). Profiles resolve
    # relative to the base file's directory, so one path hands the loader the
    # whole bundled set — in-repo and installed alike.
    def self.bundled_policy_path
      File.expand_path('../../policy/base.yaml', __dir__)
    end
  end
end

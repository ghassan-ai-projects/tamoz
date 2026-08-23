# frozen_string_literal: true

require 'tamoz/core'
require_relative 'approval/version'
require_relative 'approval/errors'
require_relative 'approval/request'
require_relative 'approval/decision'
require_relative 'approval/grant'
require_relative 'approval/answer'
require_relative 'approval/evaluator'
require_relative 'approval/policy_document'

module Tamoz
  # Approval/permission policy: one component that decides whether a tool call
  # needs approval, reading digest-pinned YAML policy data.
  module Approval
  end
end

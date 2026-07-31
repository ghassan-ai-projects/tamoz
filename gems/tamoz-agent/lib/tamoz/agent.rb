# frozen_string_literal: true

require "tamoz/graph"
require_relative "agent/version"
require_relative "agent/errors"
require_relative "agent/plan"
require_relative "agent/toolbox"
require_relative "agent/ruby_llm_model"
require_relative "agent/runtime"
require_relative "agent/cli"

module Tamoz
  module Agent
    ROOT = File.expand_path("../../..", __dir__).freeze

    def self.build(model:, root: Dir.pwd, max_plan_attempts: 3)
      Runtime.new(model:, toolbox: Toolbox.new(root:), max_plan_attempts:)
    end
  end
end

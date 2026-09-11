# frozen_string_literal: true

require "pathname"
require "tamoz/core"

require_relative "evals/version"
require_relative "evals/errors"
require_relative "evals/deep_freeze"
require_relative "evals/shape_validation"
require_relative "evals/canonical_json"
require_relative "evals/duplicate_key_detector"
require_relative "evals/schema"
require_relative "evals/artifact"
require_relative "evals/verifier"
require_relative "evals/case"
require_relative "evals/evidence"
require_relative "evals/result"
require_relative "evals/cli"

module Tamoz
  module Evals
    module_function

    DATA_ROOT = Pathname.new(File.expand_path("../..", __dir__)).freeze

    def verify(path)
      Verifier.new.verify(path)
    end
  end
end

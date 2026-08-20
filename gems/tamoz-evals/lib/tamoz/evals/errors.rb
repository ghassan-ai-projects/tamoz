# frozen_string_literal: true

module Tamoz
  module Evals
    # Builds on Tamoz::Error like every other runtime-path gem's error root:
    # tamoz-evals already declares a real tamoz-core dependency (its harness
    # subtree requires it), so there is no dependency-weight reason to stay
    # off the shared category/retryable/safe_message contract.
    class Error < Tamoz::Error
      CATEGORY = "evals"
      SAFE_MESSAGE = "An evaluation operation failed."
    end
    class InvalidArtifactError < Error
      CATEGORY = "evals_invalid_artifact"
      SAFE_MESSAGE = "The evaluation artifact is invalid."
    end
    class UnsupportedFormatError < InvalidArtifactError
      CATEGORY = "evals_unsupported_format"
      SAFE_MESSAGE = "The evaluation artifact format is unsupported."
    end
    class SchemaError < InvalidArtifactError
      CATEGORY = "evals_schema"
      SAFE_MESSAGE = "The evaluation artifact failed schema validation."
    end
    class DigestError < InvalidArtifactError
      CATEGORY = "evals_digest"
      SAFE_MESSAGE = "The evaluation artifact digest is invalid."
    end
    class ReferenceError < InvalidArtifactError
      CATEGORY = "evals_reference"
      SAFE_MESSAGE = "The evaluation artifact reference is invalid."
    end
    class ExecutionError < Error
      CATEGORY = "evals_execution"
      SAFE_MESSAGE = "The evaluation harness failed to execute."
    end
  end
end

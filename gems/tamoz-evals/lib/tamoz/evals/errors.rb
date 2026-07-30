# frozen_string_literal: true

module Tamoz
  module Evals
    class Error < StandardError; end
    class InvalidArtifactError < Error; end
    class UnsupportedFormatError < InvalidArtifactError; end
    class SchemaError < InvalidArtifactError; end
    class DigestError < InvalidArtifactError; end
    class ReferenceError < InvalidArtifactError; end
  end
end

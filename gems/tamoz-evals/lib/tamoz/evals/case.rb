# frozen_string_literal: true

module Tamoz
  module Evals
    class Case < Artifact
      def self.load(path)
        verification = Verifier.new.verify(path)
        unless verification.artifact_type == "case"
          raise InvalidArtifactError, "expected case artifact, got #{verification.artifact_type}"
        end

        new(
          attributes: verification.document,
          path: verification.path,
          digest: verification.digest
        )
      end
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Evals
    class Evidence < Artifact
      def self.load(path)
        verification = Verifier.new.verify(path)
        unless verification.artifact_type == "evidence"
          raise InvalidArtifactError,
                "expected evidence artifact, got #{verification.artifact_type}"
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

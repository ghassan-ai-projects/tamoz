# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # T5.3 (PLAN_TAMOZ_STREAM_BUILD T5.3): the authenticated
      # reconciled-outcome reference. An Experience may be admitted as
      # :observed ONLY with this reference — the independently_observed
      # boolean has no power anymore (T0.2 downgraded the default; T5.3
      # removes the flag's authority entirely). The stream's reconciled
      # Outcome is the independent observer Tamoz alone cannot be
      # (PROTOCOL §6.2); the reference names the specific observation, ties it
      # to an executed effect, proves Tamoz executed the episode, and
      # restricts learning to verdicts that actually settled the question.
      #
      # All seven fields are required; absent or unverifiable, admission is
      # refused — there is no default, only a verified reference or a refusal.
      module VerifiedOutcomeReference
        REQUIRED_FIELDS = %w[
          outcome_id outcome_digest command_id source_authority
          reconciliation_version observation_status episode_id attempt_id
        ].freeze

        # Only a reconciled verdict that SETTLED the question may be learned
        # from. `inconclusive` and `superseded_before_verification` are
        # recorded and never learned from (LIFECYCLES §6).
        LEARNABLE_VERDICTS = %w[verified refuted].freeze

        module_function

        # Returns nil when the reference authenticates against the episode,
        # or a bounded reason string when it does not. The caller (admission)
        # refuses on any non-nil reason when a reference was CLAIMED. Episode
        # keys are canonicalized to strings first — production episodes may be
        # symbol- or string-keyed, and the match must not silently refuse a
        # well-formed claim from the string-keyed path.
        def reason(reference, episode:, verify_source_authority:)
          return "missing_reconciled_outcome_reference" if reference.nil?
          return "malformed_reconciled_outcome_reference" unless reference.is_a?(Hash)

          normalized = reference.transform_keys(&:to_s)
          missing = REQUIRED_FIELDS.reject do |field|
            normalized[field].is_a?(String) && !normalized[field].empty?
          end
          return "missing_reconciled_outcome_fields: #{missing.join(",")}" unless missing.empty?

          episode_identity = episode.transform_keys(&:to_s)
          verdict = normalized.fetch("observation_status")
          unless LEARNABLE_VERDICTS.include?(verdict)
            return "unlearnable_verdict: #{verdict.byteslice(0, 64)}"
          end
          unless normalized.fetch("episode_id") == episode_identity["episode_id"].to_s &&
                 normalized.fetch("attempt_id") == episode_identity["attempt_id"].to_s
            return "foreign_episode"
          end
          unless verify_source_authority.respond_to?(:call) &&
                 verify_source_authority.call(normalized.fetch("source_authority"))
            return "forged_source_authority"
          end

          nil
        end

        # The provenance block appended to the :observed record's source_refs
        # (PROTOCOL §6.2: the Experience cites the episode id, Decision
        # digest, command id, and Outcome id, so provenance survives).
        def provenance(reference)
          normalized = reference.transform_keys(&:to_s)
          {
            "identity" => "outcome:#{normalized.fetch("outcome_id")}",
            "digest" => normalized.fetch("outcome_digest"),
            "command_id" => normalized.fetch("command_id"),
            "source_authority" => normalized.fetch("source_authority"),
            "reconciliation_version" => normalized.fetch("reconciliation_version")
          }
        end
      end
    end
  end
end

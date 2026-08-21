# frozen_string_literal: true

module Tamoz
  module Agent
    module Improvement
      # The fail-closed policy for candidate artifacts. Profile candidates are
      # validated by `Profile` and may only narrow a supplied authority baseline;
      # skill/config candidates never carry authority-shaped content.
      module CandidatePolicy
        SECRET_KEYS = %w[secret token password private_key].freeze
        AUTHORITY_FIELDS = %w[
          allowed_tools approval_required allow_changes roots credentials egress
          capability authority profile_authority authority_delta grants_authority
        ].freeze
        PROFILE_AUTHORITY_KEYS = %w[authority profile_authority].freeze
        SAFETY_ORDER = %w[read_only idempotent reconcilable unsafe].freeze

        module_function

        def validate!(proposal:, candidate:, current_authority:)
          reject_unsafe_content!(proposal, candidate)
          authority = candidate['authority'] || candidate['profile_authority']
          return validate_profile!(proposal, authority, current_authority) if proposal.scope == 'profile'
          return if authority.nil?

          raise ImprovementPolicyError, "#{proposal.scope} candidate may not carry authority"
        end

        def reject_unsafe_content!(proposal, candidate)
          if Tamoz::Core.secret_shaped?(candidate)
            raise ImprovementPolicyError, 'candidate artifact contains secret-shaped content'
          end

          scanned = if proposal.scope == 'profile'
                      candidate.reject { |key, _| PROFILE_AUTHORITY_KEYS.include?(String(key)) }
                    else
                      candidate
                    end
          fields = named_fields(scanned)
          return if !fields.intersect?(SECRET_KEYS) && !fields.intersect?(AUTHORITY_FIELDS)

          raise ImprovementPolicyError, 'candidate artifact declares secrets or an authority change'
        end

        def validate_profile!(proposal, authority, current_authority)
          unless current_authority
            raise ImprovementPolicyError, 'profile candidate requires a current authority baseline'
          end
          raise ImprovementPolicyError, 'profile candidate must carry validated authority' unless authority.is_a?(Hash)

          profile = Profile.from_authority(authority, source: "candidate #{proposal.to_digest}")
          unless profile.profile_id == proposal.profile_id && profile.canonical_digest == proposal.to_digest
            raise EvaluatorTamperError, 'profile candidate authority does not match its digest'
          end

          assert_narrower!(proposal, profile, current_authority)
        rescue Profile::ValidationError => e
          raise ImprovementPolicyError, "candidate profile is invalid: #{e.message}"
        end

        def assert_narrower!(proposal, candidate, current_authority)
          current = authority_snapshot(current_authority)
          unless current['canonical_digest'] == proposal.from_digest
            raise ImprovementPolicyError, 'candidate authority does not match the proposal source'
          end

          immutable = %w[canonical_root model_roles checks egress profile_id profile_version]
          immutable.each do |key|
            next if current[key] == candidate.authority_snapshot[key]

            raise ImprovementPolicyError, "candidate changes protected authority field #{key}"
          end
          old_tools = current.fetch('tools')
          new_tools = candidate.authority_snapshot.fetch('tools')
          return if narrower_tools?(old_tools, new_tools) &&
                    narrower_policy?(current.fetch('policy'), candidate.authority_snapshot.fetch('policy'))

          raise ImprovementPolicyError, 'candidate authority is wider than the current profile'
        end

        def narrower_tools?(current, candidate)
          (Array(candidate['allowed']) - Array(current['allowed'])).empty? &&
            (Array(current['approval_required']) - Array(candidate['approval_required'])).empty?
        end

        def narrower_policy?(current, candidate)
          return false if !current['allow_changes'] && candidate['allow_changes']

          old = SAFETY_ORDER.index(current['default_check_safety'])
          new = SAFETY_ORDER.index(candidate['default_check_safety'])
          old && new && new <= old && policy_without_surface(current) == policy_without_surface(candidate)
        end

        def policy_without_surface(policy)
          policy.except('tool_catalog_digest', 'allow_changes', 'default_check_safety')
        end

        def authority_snapshot(authority)
          return authority.authority_snapshot if authority.respond_to?(:authority_snapshot)

          authority
        end

        def named_fields(value)
          case value
          when Hash
            value.each_with_object([]) do |(key, entry), fields|
              fields << String(key)
              fields.concat(named_fields(entry))
            end
          when Array
            value.flat_map { |entry| named_fields(entry) }
          else
            []
          end
        end
      end
    end
  end
end

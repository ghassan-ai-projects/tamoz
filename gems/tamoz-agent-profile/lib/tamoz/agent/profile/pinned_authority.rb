# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # Rebuilds a profile from the authority snapshot a durable session pinned, through the same validators.
      module PinnedAuthority
        KEYS = %w[
          profile_id profile_version canonical_digest canonical_root model_roles checks tools policy egress
        ].freeze
        OPTIONAL_KEYS = %w[model_roles checks egress].freeze

        module_function

        def document(snapshot, source)
          raise ValidationError, "#{source}: pinned profile authority must be a mapping" unless snapshot.is_a?(Hash)

          hash = Profile.normalize_keys(snapshot)
          digest = enforce_shape!(hash, source)
          synthetic = synthetic_document(hash)
          validate_sections!(synthetic, source)
          Profile.new(Fields.build(synthetic, digest:, suggestion: false, pinned: true))
        end

        def enforce_shape!(hash, source)
          enforce_key_set!(hash, source)
          digest = hash.fetch('canonical_digest')
          unless Tamoz::Core.valid_digest?(digest)
            raise ValidationError, "#{source}: pinned authority digest is not a sha256: digest"
          end

          ContentScanner.call(hash.except('canonical_digest'), source, [])
          digest
        end

        def enforce_key_set!(hash, source)
          unknown = hash.keys - KEYS
          unless unknown.empty?
            raise ValidationError,
                  "#{source}: unknown pinned authority fields #{unknown.sort.inspect}"
          end

          missing = KEYS - hash.keys - OPTIONAL_KEYS
          return if missing.empty?

          raise ValidationError, "#{source}: pinned authority is missing #{missing.sort.inspect}"
        end

        def synthetic_document(hash)
          synthetic = {
            'profile' => {
              'schema_version' => SCHEMA_VERSION, 'profile_id' => hash.fetch('profile_id'),
              'profile_version' => hash.fetch('profile_version'), 'canonical_root' => hash.fetch('canonical_root')
            },
            'roots' => { 'workspace' => hash.fetch('canonical_root') },
            'model_roles' => hash['model_roles'] || {},
            'checks' => hash['checks'] || {},
            'tools' => hash.fetch('tools'),
            'policy' => hash.fetch('policy')
          }
          synthetic['egress'] = hash['egress'] if hash.key?('egress')
          synthetic
        end

        def validate_sections!(synthetic, source)
          DocumentValidator.profile_fields!(synthetic.fetch('profile'), source)
          DocumentValidator.roots!(synthetic, synthetic.fetch('profile'), source)
          DocumentValidator.model_roles!(synthetic, source)
          CheckSpecValidator.call(synthetic, source)
          tools = AuthorityValidator.tools!(synthetic, source)
          AuthorityValidator.policy!(synthetic, tools, source)
          EgressValidator.call(synthetic, source)
        end
      end

      private_constant :PinnedAuthority
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # Reads an operator profile file, refuses evidence-only and in-project copies, and validates every section.
      module DocumentLoader
        module_function

        def load(expanded_path, suggestion:, env:, &capture)
          refuse_evidence_only_activation!(expanded_path, env:) unless suggestion
          bytes = SecureFile.open_verified(expanded_path, permissions: !suggestion) do |handle|
            SecureFile.read_bytes(handle, expanded_path)
          end
          capture&.call(bytes)
          hash = parse_mapping(bytes, expanded_path)
          validate_schema!(hash, expanded_path)
          fields = Fields.build(hash, digest: Tamoz::Core.digest(DIGEST_DOMAIN, hash), suggestion:)
          verify_outside_root!(expanded_path, fields.canonical_root, expanded_path) unless suggestion
          Profile.new(fields)
        end

        def refuse_evidence_only_activation!(path, env:)
          return unless Profile.suggestion_path?(path, env:)

          raise ValidationError,
                "#{path} is inside #{SUGGESTION_DIRECTORY}/ and is evidence " \
                'only; preview or import it instead of activating it'
        end

        def parse_mapping(bytes, path)
          YamlScanner.call(bytes, path)
          data = safe_parse(bytes, path)
          raise ValidationError, "#{path}: profile must be a YAML mapping" unless data.is_a?(Hash)

          Profile.normalize_keys(data).tap { |hash| hash.delete('adoption') }
        end

        def safe_parse(text, path)
          Psych.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: true)
        rescue Psych::Exception => e
          raise ValidationError, "#{path}: invalid YAML: #{e.message}"
        end

        def validate_schema!(hash, path)
          unknown = hash.keys - TOP_LEVEL_KEYS
          raise ValidationError, "#{path}: unknown sections #{unknown.sort.inspect}" unless unknown.empty?

          profile = Profile.required_hash(hash, 'profile', path)
          enforce_schema_version!(profile, path)
          unknown_profile = profile.keys - PROFILE_KEYS
          unless unknown_profile.empty?
            raise ValidationError, "#{path}: unknown profile fields #{unknown_profile.sort.inspect}"
          end

          ContentScanner.call(hash, path, [])
          validate_sections!(hash, profile, path)
        end

        def enforce_schema_version!(profile, path)
          version = profile['schema_version']
          raise ValidationError, "#{path}: profile.schema_version must be an integer" unless version.is_a?(Integer)
          if version > SCHEMA_VERSION
            raise ValidationError,
                  "#{path}: profile schema version #{version} is newer than supported #{SCHEMA_VERSION}"
          end
          return if version == SCHEMA_VERSION

          raise ValidationError, "#{path}: no migration registered from schema version #{version}"
        end

        def validate_sections!(hash, profile, path)
          DocumentValidator.profile_fields!(profile, path)
          DocumentValidator.roots!(hash, profile, path)
          DocumentValidator.model_roles!(hash, path)
          DocumentValidator.budgets!(hash, path)
          CheckSpecValidator.call(hash, path)
          tools = AuthorityValidator.tools!(hash, path)
          AuthorityValidator.policy!(hash, tools, path)
          EgressValidator.call(hash, path)
        end

        def verify_outside_root!(expanded_path, canonical_root, path)
          ancestors(File.dirname(expanded_path)).each do |directory|
            refuse_inside_root!(path, canonical_root) if File.identical?(directory, canonical_root)
          end
        rescue SystemCallError => e
          raise ValidationError,
                "#{path}: cannot verify the profile lives outside its canonical_root " \
                "#{canonical_root.inspect}: #{e.message}"
        end

        def ancestors(directory)
          chain = [directory]
          chain << File.dirname(chain.last) until File.dirname(chain.last) == chain.last
          chain
        end

        def refuse_inside_root!(path, canonical_root)
          raise ValidationError,
                "#{path}: profile must not live inside its own canonical_root " \
                "#{canonical_root.inspect}; operator profiles live outside the project"
        end
      end

      private_constant :DocumentLoader
    end
  end
end

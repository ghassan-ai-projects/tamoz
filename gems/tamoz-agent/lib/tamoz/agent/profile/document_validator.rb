# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # The declared sections of a profile document, checked for shape: the
      # profile block's identity fields, the roots, the model roles and their
      # credential REFERENCES, and the budgets.
      #
      # Holds only the path, because that is what every one of these refusals has
      # in common — the data varies per section and is handed in by the loader,
      # which already fetched it. What a section MEANS for authority lives in
      # AuthorityValidator; what a check may execute lives in CheckSpecValidator.
      # This class only answers "is this section the right shape".
      #
      # Pinned by test/agent_profile_test.rb and
      # test/agent_profile_schema_seams_test.rb (profile id pattern, reserved
      # legacy id, unknown fields, model role name, provider, credential_ref).
      #
      # :reek:MissingSafeMethod — every entry point is a refusal that raises.
      # :reek:FeatureEnvy — the per-field predicates interrogate the untrusted
      # document handed to them; the data is the subject, not state of our own.
      # :reek:TooManyStatements — `root!`, `roots!` and `validate_role!` each walk
      # one section field by field; the list of refusals IS the schema.
      # :reek:TooManyMethods — five entry points plus one named refusal per field;
      # merging any of them back would only re-inline the check it names.
      # :reek:DataClump — (root, field) is a value and the name the error message
      # calls it by. `root!` is used for two different fields
      # (profile.canonical_root and roots.workspace), so the label cannot be
      # derived and has to travel with the value.
      class DocumentValidator
        MAX_DESCRIPTION_BYTES = 1024
        MAX_ROOT_BYTES = 4096
        MAX_MODEL_BYTES = 256

        def self.profile_fields!(profile, path)
          new(path).profile_fields!(profile)
        end

        def self.root!(root, path, field)
          new(path).root!(root, field)
        end

        def self.roots!(hash, profile, path)
          new(path).roots!(hash, profile)
        end

        def self.model_roles!(hash, path)
          new(path).model_roles!(hash)
        end

        def self.budgets!(hash, path)
          new(path).budgets!(hash)
        end

        def initialize(path)
          @path = path
        end

        def profile_fields!(profile)
          validate_id!(profile['profile_id'])
          validate_version!(profile['profile_version'])
          root!(profile['canonical_root'], 'profile.canonical_root')
          validate_description!(profile['description'])
        end

        # An absolute path to an existing directory that is not itself a symlink.
        # The SystemCallError rescue covers every File call below it: a root we
        # cannot stat is unavailable, not invalid, and must not leak errno detail.
        def root!(root, field)
          validate_root_spelling!(root, field)
          validate_root_target!(root, field)
        rescue SystemCallError
          raise ValidationError, "#{@path}: #{field} is unavailable"
        end

        def roots!(hash, profile)
          roots = Profile.required_hash(hash, 'roots', @path)
          refuse_unknown!(roots.keys - ROOTS_KEYS, 'roots')

          workspace = roots['workspace']
          root!(workspace, 'roots.workspace')
          return if File.expand_path(workspace) == File.expand_path(profile.fetch('canonical_root'))

          raise ValidationError, "#{@path}: roots.workspace must equal profile.canonical_root in schema v1"
        end

        def model_roles!(hash)
          roles = hash['model_roles'] || {}
          raise ValidationError, "#{@path}: model_roles must be a mapping" unless roles.is_a?(Hash)

          roles.each { |name, role| validate_role!(name, role) }
        end

        def budgets!(hash)
          budgets = hash['budgets'] || {}
          raise ValidationError, "#{@path}: budgets must be a mapping" unless budgets.is_a?(Hash)

          refuse_unknown!(budgets.keys - BUDGET_KEYS, 'budget')
          budgets.each { |key, value| validate_budget!(key, value) }
        end

        private

        # How the path is written: absolute, bounded, no NUL, and not one of the
        # bare words that name a host implicitly rather than a directory.
        def validate_root_spelling!(root, field)
          unless root.is_a?(String) && !root.empty? && root.start_with?(File::SEPARATOR) &&
                 root.bytesize <= MAX_ROOT_BYTES && !root.include?("\0")
            raise ValidationError, "#{@path}: #{field} must be an absolute path"
          end
          return unless TIMEZONE_WORDS.include?(root.downcase)

          raise ValidationError, "#{@path}: #{field} must not be an implicit host reference"
        end

        # What the path points AT. Every call here can raise SystemCallError, which
        # `root!` turns into "unavailable" so errno detail never reaches the
        # operator's message.
        def validate_root_target!(root, field)
          expanded = File.expand_path(root)
          raise ValidationError, "#{@path}: #{field} must not end in a symlink" if File.lstat(expanded).symlink?
          return if File.directory?(expanded)

          raise ValidationError, "#{@path}: #{field} must be an existing directory"
        end

        def refuse_unknown!(unknown, section_name)
          return if unknown.empty?

          raise ValidationError, "#{@path}: unknown #{section_name} fields #{unknown.sort.inspect}"
        end

        def validate_id!(id)
          unless id.is_a?(String) && PROFILE_ID_PATTERN.match?(id)
            raise ValidationError, "#{@path}: profile.profile_id must match #{PROFILE_ID_PATTERN.inspect}"
          end
          # DR-5 RC3: "legacy" is the session-record sentinel for sessions that
          # predate trusted profiles (SessionRecords::LEGACY_PROFILE_ID). A real
          # profile named "legacy" would be misclassified by the shipped cli.rb
          # sentinel guard and silently destroy the sentinel semantics, so the id
          # is reserved and refused here, at load.
          return unless id == SessionRecords::LEGACY_PROFILE_ID

          raise ValidationError,
                "#{@path}: profile.profile_id \"legacy\" is reserved for sessions that " \
                'predate trusted profiles; choose another profile id'
        end

        def validate_version!(version)
          return if version.is_a?(String) && PROFILE_VERSION_PATTERN.match?(version)

          raise ValidationError,
                "#{@path}: profile.profile_version must match #{PROFILE_VERSION_PATTERN.inspect}"
        end

        def validate_description!(description)
          return unless description
          return if description.is_a?(String) && description.bytesize <= MAX_DESCRIPTION_BYTES

          raise ValidationError,
                "#{@path}: profile.description must be a string of at most #{MAX_DESCRIPTION_BYTES} bytes"
        end

        def validate_role!(name, role)
          named = name.inspect
          raise ValidationError, "#{@path}: invalid model role name #{named}" unless valid_role_name?(name)
          raise ValidationError, "#{@path}: model role #{named} must be a mapping" unless role.is_a?(Hash)

          refuse_unknown!(role.keys - MODEL_ROLE_KEYS, 'model role')
          validate_provider!(role['provider'], name)
          validate_model!(role['model'], name)
          credential_ref!(role['credential_ref'], name) if role.key?('credential_ref')
          normalized_settings!(role['normalized_settings'], name) if role.key?('normalized_settings')
        end

        # :reek:UtilityFunction — a pure name-shape predicate.
        def valid_role_name?(name)
          name.is_a?(String) && PROFILE_ID_PATTERN.match?(name)
        end

        def validate_provider!(provider, role)
          return if provider.is_a?(String) &&
                    (KNOWN_PROVIDERS.include?(provider) || provider == 'assume_model_exists')

          raise ValidationError, "#{@path}: unknown provider #{provider.inspect} for role #{role.inspect}"
        end

        def validate_model!(model, role)
          return if model.is_a?(String) && !model.empty? && model.bytesize <= MAX_MODEL_BYTES

          raise ValidationError, "#{@path}: invalid model identifier for role #{role.inspect}"
        end

        # P0B/§4.2: a bounded mapping of plain strings (endpoint overrides and
        # the like). Values must be non-secret config; secrets belong in
        # credential_ref, whose validator rejects value-shaped entries.
        def normalized_settings!(settings, role)
          named = role.inspect
          raise ValidationError, "#{@path}: normalized_settings for #{named} must be a mapping" unless settings.is_a?(Hash)

          settings.each do |key, value|
            unless key.is_a?(String) && value.is_a?(String) &&
                   key.bytesize <= MAX_MODEL_BYTES && value.bytesize <= MAX_MODEL_BYTES
              raise ValidationError,
                    "#{@path}: normalized_settings for #{named} must be a bounded string mapping"
            end
          end
        end

        # A NAME of an environment variable, never a value. The same pattern the
        # egress declaration's credential_refs use, so there is one spelling of
        # "this is a reference, not a secret".
        def credential_ref!(ref, role)
          named = role.inspect
          raise ValidationError, "#{@path}: credential_ref for #{named} must be a mapping" unless ref.is_a?(Hash)

          refuse_unknown!(ref.keys - CREDENTIAL_REF_KEYS, 'credential_ref')
          unless ref['kind'] == 'env'
            raise ValidationError, "#{@path}: credential_ref kind must be \"env\" for role #{named}"
          end

          reference = ref['name']
          return if reference.is_a?(String) && CREDENTIAL_REF_PATTERN.match?(reference)

          raise ValidationError,
                "#{@path}: credential_ref name for role #{named} must match " \
                "#{CREDENTIAL_REF_PATTERN.inspect}"
        end

        def validate_budget!(key, value)
          return if value.is_a?(Numeric) && value.finite? && !value.negative?

          raise ValidationError, "#{@path}: budgets.#{key} must be a non-negative finite number"
        end
      end
    end
  end
end

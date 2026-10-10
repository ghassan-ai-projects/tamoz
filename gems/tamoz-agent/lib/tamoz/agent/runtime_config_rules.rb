# frozen_string_literal: true

module Tamoz
  module Agent
    class RuntimeDirectory
      # Load-time validation of the operator configuration; every rule raises RuntimeDirectory::Error.
      module ConfigRules
        SURFACE_ID = /\A[a-z0-9][a-z0-9_-]{0,63}\z/
        CHANNEL_KEYS = %w[kind enabled revision profile credential_ref stream_id transport settings
                          admission approvals rendering limits threading].freeze
        THREADING_MODES = Tamoz::Comms::SurfaceDescriptor::THREADING_MODES
        CHANNEL_FIELD_RULES = {
          'kind' => [lambda { |value|
            Tamoz::Comms::SurfaceDescriptor.valid_kind?(value)
          }, 'must be a lowercase channel name'],
          'revision' => [->(value) { value.is_a?(Integer) && value.positive? }, 'must be a positive integer'],
          'stream_id' => [->(value) { value.is_a?(String) && !value.empty? }, 'is mandatory and must be a string'],
          'enabled' => [->(value) { [true, false].include?(value) }, 'must be a boolean'],
          'profile' => [->(value) { value.is_a?(String) && !value.empty? }, 'must be a non-empty string'],
          'threading' => [->(value) { value.nil? || THREADING_MODES.include?(value) },
                          "must be one of #{THREADING_MODES.join(', ')}"]
        }.freeze

        module_function

        def validate_document!(document)
          validate_schema_version!(document)
          validate_workspace_root!(document)
          validate_channels!(document['channels'])
          validate_subagents!(document['harness'])
          validate_models!(document['models'])
        end

        # Strict per-entry validation: the kind is a well-formed name (the closed set is the CLI's channel
        # registry), and each field's rule is checked in this order.
        def validate_channel!(surface_id, entry)
          label = "channels.#{surface_id}"
          validate_channel_shape!(label, surface_id, entry)
          CHANNEL_FIELD_RULES.each do |key, (valid, message)|
            raise Error, "#{label}.#{key} #{message}" unless valid.call(entry[key])
          end
          validate_channel_credential!(label, entry['credential_ref'])
          direct = entry.dig('admission', 'direct')
          unless direct.nil? || Tamoz::Comms::SurfaceDescriptor::ADMISSION_MODES.include?(direct)
            raise Error, "#{label}.admission.direct must be one of " \
                         "#{Tamoz::Comms::SurfaceDescriptor::ADMISSION_MODES.join(', ')}"
          end
          entry.freeze
        end

        def validate_channel_credential!(label, credential)
          return if credential.is_a?(Hash) && credential['kind'] == 'env' &&
                    credential['name'].is_a?(String) && !credential['name'].empty?

          raise Error, "#{label}.credential_ref must be {kind: env, name: ENV_NAME}"
        end

        # A surface id names a folder under the runtime; a removed key fails by name, never silently.
        def validate_channel_shape!(label, surface_id, entry)
          raise Error, "#{label}: a surface id is lowercase letters, digits, - and _" unless
            surface_id.is_a?(String) && surface_id.match?(SURFACE_ID)
          raise Error, "#{label} must be a mapping" unless entry.is_a?(Hash)

          unknown = entry.keys - CHANNEL_KEYS
          return if unknown.empty?

          raise Error, "#{label}.#{unknown.first} is not a channel field; remove the channels block and run " \
                       '`tamoz channel add` again'
        end

        def validate_schema_version!(document)
          version = document.dig('runtime', 'schema_version')
          return if version == SCHEMA_VERSION

          raise Error, "runtime configuration schema_version #{version.inspect} is not supported " \
                       "(expected #{SCHEMA_VERSION}); run `tamoz setup` on a new runtime directory"
        end

        def validate_workspace_root!(document)
          root = document.dig('workspace', 'root')
          return if root.is_a?(String) && !root.empty?

          raise Error, 'runtime configuration must set workspace.root'
        end

        def validate_channels!(raw)
          return unless raw.is_a?(Hash)

          raw.each_key { |surface_id| validate_channel!(surface_id, raw.fetch(surface_id)) }
          profiles = raw.values.map { |entry| entry['profile'] }.uniq
          raise Error, "every channel must name one profile, not #{profiles.join(', ')}" if profiles.length > 1
        end

        def validate_subagents!(harness)
          return if harness.nil?
          raise Error, 'harness must be a mapping' unless harness.is_a?(Hash)

          roles = harness['subagents']
          return if roles.nil?
          raise Error, 'harness.subagents must be a unique list of role names' unless subagent_roles_list?(roles)

          roles.each { |role| Tamoz::Harness::SubagentRoles.shipped.fetch(role) }
        rescue Tamoz::Harness::Error => e
          raise Error, "harness.subagents: #{e.message}"
        end

        def subagent_roles_list?(roles) = roles.is_a?(Array) && roles.all?(String) && roles.uniq == roles

        def validate_models!(raw)
          RuntimeModels.parse(raw)
        rescue ArgumentError => e
          raise Error, e.message
        end
      end
    end
  end
end

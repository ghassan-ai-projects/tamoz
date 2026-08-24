# frozen_string_literal: true

require "psych"
require "fileutils"

require "tamoz/comms"

module Tamoz
  module Agent
    # The operator-owned runtime directory: one place a worker is pointed at, and
    # the only place its authority comes from.
    #
    #   <runtime-dir>/
    #     config.yaml        operator configuration (workspace root, sources, bounds, channels)
    #     profiles/*.yaml    trusted profiles
    #     runtime.sqlite3    schedules, request inboxes, checkpoints
    #
    # One database, deliberately. `materialize_due` claims a schedule and enqueues
    # its request in ONE transaction; splitting schedules from inboxes across files
    # would put that transaction across two databases and lose the atomicity that
    # makes "exactly one occurrence" true. The per-thread `<thread>.sqlite3` layout
    # the interactive CLI uses stays as it is — it has no scheduler to be atomic
    # with.
    #
    # Everything here is operator authority. Nothing in the WORKSPACE — the
    # repository the agent reads and edits — is ever consulted for configuration.
    # That separation is the whole point: a checkout the agent can write to must
    # never be able to widen what the agent may do.
    #
    # Schema 2 (COMMS_DESIGN §14): a strict `channels:` mapping. Schema 1 loads
    # unchanged as "no channels". Startup never rewrites operator authority —
    # `config migrate` is the only writer, and it is explicit and atomic.
    class RuntimeDirectory
      class Error < Tamoz::Agent::Error; end

      CONFIG_FILE = "config.yaml"
      DATABASE_FILE = "runtime.sqlite3"
      PROFILES_DIR = "profiles"
      SCHEMA_VERSION = 2
      LEGACY_SCHEMA_VERSION = 1
      SCHEMA_VERSIONS = [LEGACY_SCHEMA_VERSION, SCHEMA_VERSION].freeze

      # Sources a runtime may enable. Closed set: an operator can turn on what
      # Tamoz ships, and nothing else. There is no plugin path by construction.
      KNOWN_SOURCES = %w[skills memory mcp websearch].freeze

      attr_reader :path, :config

      def self.resolve(path: nil, env: ENV)
        candidate = path || env["TAMOZ_RUNTIME_DIR"]
        raise Error, "no runtime directory: pass --runtime-dir or set TAMOZ_RUNTIME_DIR" if candidate.nil?

        new(File.expand_path(candidate))
      end

      def initialize(path)
        @path = path
        @config = load_config
      end

      # `tamoz worker` and friends refuse to run against a directory anyone else
      # can read or write: it holds the schedules and profiles that decide what
      # runs unattended.
      def self.create!(path, workspace:)
        ensure_private_runtime_directories!(path)
        write_default_config!(path, workspace:) unless File.exist?(config_path(path))
        new(path)
      end

      # `tamoz config migrate`: schema 1 -> 2, explicitly and atomically. The
      # ORIGINAL file is copied to a timestamped backup before the migration,
      # and the new file lands by atomic rename, so a crash or a partial write
      # can never leave a half-migrated config that startup would accept.
      # :reek:TooManyStatements -- one migration sequence with a validation
      #   gate, a backup, and an atomic rename.
      def self.migrate!(path, env: ENV)
        directory = resolve(path:, env:)
        config_path = config_path(directory.path)
        document = read_config_document(config_path)
        version = document.dig("runtime", "schema_version")
        return [:already_current, directory] if version == SCHEMA_VERSION

        ensure_legacy_schema!(version)

        migrated = migrated_document(document)
        # The whole migrated document must validate before anything is written:
        # a config that would be refused after migration must be refused now,
        # with the original file still untouched.
        validate_document!(migrated)

        backup = backup_config!(config_path)
        write_migrated_config!(config_path, migrated)
        [:migrated, new(directory.path), backup]
      end

      def database_path = File.join(path, DATABASE_FILE)
      def profiles_path = File.join(path, PROFILES_DIR)
      def workspace_root = @config.dig("workspace", "root")

      # Approval policy source of truth: an optional operator override in the
      # run config, else the policy data bundled with tamoz-approval.
      def approval_policy_path
        value = @config.dig("approval", "policy_path")
        value.is_a?(String) && !value.empty? ? File.expand_path(value) : Tamoz::Approval.bundled_policy_path
      end

      def approval_profile
        value = @config.dig("approval", "profile")
        value.is_a?(String) && !value.empty? ? value : "implement"
      end

      # The sources the OPERATOR enabled. Content, model output, skills, MCP
      # metadata and memory never reach this list — they cannot, because it is
      # read from a file outside the workspace and validated against a closed set.
      def enabled_sources
        raw = @config["sources"]
        return [] unless raw.is_a?(Hash)

        raw.filter_map do |name, settings|
          next unless settings.is_a?(Hash) && settings["enabled"] == true
          unless KNOWN_SOURCES.include?(name)
            raise Error, "unknown capability source #{name.inspect} " \
                         "(known: #{KNOWN_SOURCES.join(", ")})"
          end

          name
        end.freeze
      end

      def source_settings(name)
        settings = @config.dig("sources", name)
        settings.is_a?(Hash) ? settings : {}
      end

      # The deployed channel surfaces (COMMS_DESIGN §14): surface_id -> entry,
      # validated strictly at load against the closed kind list and the
      # mandatory revision/expected_bot_id fields. Deep field validation is
      # SurfaceDescriptor's contract; this is the fast, load-time gate.
      def channels
        raw = @config["channels"]
        return {}.freeze unless raw.is_a?(Hash)

        raw.each_with_object({}) do |(surface_id, entry), out|
          out[surface_id] = self.class.validate_channel!(surface_id, entry)
        end.freeze
      end

      # Where operator-authored skills live. Inside the runtime directory by
      # default, and never inside the workspace: a skill is INSTRUCTIONS, and a
      # checkout the agent can write to must not be able to write its own.
      def skills_root
        configured = source_settings("skills")["root"]
        return File.join(path, "skills") if configured.nil?

        resolved = File.expand_path(configured, path)
        workspace = File.expand_path(workspace_root)
        if resolved == workspace || resolved.start_with?("#{workspace}#{File::SEPARATOR}")
          raise Error, "skills root #{resolved} is inside the workspace; " \
                       "skills are instructions and must live outside the tree being worked on"
        end

        resolved
      end

      def stream_bounds
        raw = @config["stream"]
        raw.is_a?(Hash) ? raw : {}
      end

      def self.validate_document!(document)
        validate_schema_version!(document)
        validate_workspace_root!(document)
        validate_channels!(document["channels"])
      end

      # Strict per-entry validation (COMMS_DESIGN §14): the kind comes from the
      # closed list in tamoz-comms, the revision is mandatory and positive, and
      # expected_bot_id is mandatory — the identity the gateway pins with getMe.
      # :reek:TooManyStatements -- one per-field validation sequence.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      #   -- one validation sequence per field, checked in the design's order.
      def self.validate_channel!(surface_id, entry)
        label = "channels.#{surface_id}"
        raise Error, "#{label} must be a mapping" unless entry.is_a?(Hash)

        kind = entry["kind"]
        unless Tamoz::Comms::SurfaceDescriptor::KINDS.include?(kind)
          raise Error, "#{label}.kind must be one of " \
                       "#{Tamoz::Comms::SurfaceDescriptor::KINDS.join(', ')}"
        end
        unless entry["revision"].is_a?(Integer) && entry["revision"].positive?
          raise Error, "#{label}.revision must be a positive integer"
        end
        unless entry["expected_bot_id"].is_a?(Integer)
          raise Error, "#{label}.expected_bot_id is mandatory and must be an integer"
        end
        unless [true, false].include?(entry["enabled"])
          raise Error, "#{label}.enabled must be a boolean"
        end
        unless entry["profile"].is_a?(String) && !entry["profile"].empty?
          raise Error, "#{label}.profile must be a non-empty string"
        end
        unless entry["threading"].nil? ||
               Tamoz::Comms::SurfaceDescriptor::THREADING_MODES.include?(entry["threading"])
          raise Error, "#{label}.threading must be one of " \
                       "#{Tamoz::Comms::SurfaceDescriptor::THREADING_MODES.join(', ')}"
        end

        credential = entry["credential_ref"]
        unless credential.is_a?(Hash) && credential["kind"] == "env" &&
               credential["name"].is_a?(String) && !credential["name"].empty?
          raise Error, "#{label}.credential_ref must be {kind: env, name: ENV_NAME}"
        end

        direct = entry.dig("admission", "direct")
        unless direct.nil? ||
               Tamoz::Comms::SurfaceDescriptor::ADMISSION_MODES.include?(direct)
          raise Error, "#{label}.admission.direct must be one of " \
                       "#{Tamoz::Comms::SurfaceDescriptor::ADMISSION_MODES.join(', ')}"
        end
        entry.freeze
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      class << self
        private

        def config_path(path)
          File.join(path, CONFIG_FILE)
        end

        def ensure_private_runtime_directories!(path)
          FileUtils.mkdir_p(path, mode: 0o700)
          File.chmod(0o700, path)
          profiles_path = File.join(path, PROFILES_DIR)
          FileUtils.mkdir_p(profiles_path, mode: 0o700)
          File.chmod(0o700, profiles_path)
        end

        def write_default_config!(path, workspace:)
          document = {
            "runtime" => {"schema_version" => SCHEMA_VERSION},
            "workspace" => {"root" => File.expand_path(workspace)},
            "sources" => {},
            "channels" => {}
          }
          config_path = config_path(path)
          File.write(config_path, Psych.dump(document))
          File.chmod(0o600, config_path)
        end

        def read_config_document(config_path)
          Psych.safe_load_file(config_path, permitted_classes: [], aliases: false)
        end

        def ensure_legacy_schema!(version)
          return if version == LEGACY_SCHEMA_VERSION

          raise Error, "runtime configuration schema_version #{version.inspect} " \
                       "is not supported (expected #{SCHEMA_VERSION} or #{LEGACY_SCHEMA_VERSION})"
        end

        def migrated_document(document)
          document.merge(
            "runtime" => {"schema_version" => SCHEMA_VERSION},
            "channels" => {}
          )
        end

        def backup_config!(config_path)
          backup = "#{config_path}.bak-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
          FileUtils.cp(config_path, backup)
          File.chmod(0o600, backup)
          backup
        end

        def write_migrated_config!(config_path, document)
          temp = "#{config_path}.tmp-#{Process.pid}"
          File.write(temp, Psych.dump(document))
          File.chmod(0o600, temp)
          File.rename(temp, config_path)
        end

        def validate_schema_version!(document)
          version = document.dig("runtime", "schema_version")
          return if SCHEMA_VERSIONS.include?(version)

          raise Error, "runtime configuration schema_version #{version.inspect} " \
                       "is not supported (expected #{SCHEMA_VERSION} or #{LEGACY_SCHEMA_VERSION})"
        end

        def validate_workspace_root!(document)
          root = document.dig("workspace", "root")
          return if root.is_a?(String) && !root.empty?

          raise Error, "runtime configuration must set workspace.root"
        end

        def validate_channels!(raw)
          return unless raw.is_a?(Hash)

          raw.each_key { |surface_id| validate_channel!(surface_id, raw.fetch(surface_id)) }
        end
      end

      private

      def load_config
        ensure_runtime_directory_available
        config_path = private_config_path
        document = read_config_document(config_path)
        raise Error, "runtime configuration must be a mapping" unless document.is_a?(Hash)

        self.class.validate_document!(document)
        document.freeze
      end

      def ensure_runtime_directory_available
        unless File.directory?(path)
          raise Error, "runtime directory #{path} does not exist; run 'tamoz init' first"
        end

        assert_private!(path, "runtime directory")
      end

      def private_config_path
        config_path = self.class.send(:config_path, path)
        raise Error, "#{config_path} does not exist; run 'tamoz init' first" unless File.exist?(config_path)

        assert_private!(config_path, "runtime configuration")
        config_path
      end

      def read_config_document(config_path)
        self.class.send(:read_config_document, config_path)
      rescue Psych::Exception => error
        raise Error, "runtime configuration is not valid YAML: #{error.message}"
      end

      def assert_private!(target, label)
        mode = File.stat(target).mode
        return if (mode & 0o077).zero?

        raise Error, "#{label} #{target} is accessible to group or others " \
                     "(mode #{format("%o", mode & 0o777)}); it carries unattended authority"
      end
    end
  end
end

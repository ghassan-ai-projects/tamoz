# frozen_string_literal: true

require "psych"

require "tamoz/comms"
require_relative "runtime_models"
require_relative "runtime_config_rules"

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
      KNOWN_SOURCES = %w[skills memory mcp websearch probes].freeze
      CHAT_PROFILE = 'chat'

      attr_reader :path, :config, :models

      def self.resolve(path: nil, env: ENV)
        candidate = path || env["TAMOZ_RUNTIME_DIR"]
        raise Error, "no runtime directory: pass --runtime-dir or set TAMOZ_RUNTIME_DIR" if candidate.nil?

        new(File.expand_path(candidate))
      end

      def initialize(path)
        @path = path
        @config = load_config
        @models = RuntimeModels.parse(@config['models'])
      end

      # `tamoz worker` and friends refuse to run against a directory anyone else
      # can read or write: it holds the schedules and profiles that decide what
      # runs unattended.
      def self.create!(path, workspace:, models: {})
        ConfigRules.validate_models!(models)
        fresh = !File.exist?(config_path(path))
        require_workspace_directory!(workspace) if fresh

        ensure_private_runtime_directories!(path)
        write_default_config!(path, workspace:, models:) if fresh
        new(path)
      end

      # `tamoz config migrate`: schema 1 -> 2, explicitly and atomically. The
      # ORIGINAL file is copied to a timestamped backup before the migration,
      # and the new file lands by atomic rename, so a crash or a partial write
      # can never leave a half-migrated config that startup would accept.
      def self.migrate!(path, env: ENV)
        directory = resolve(path:, env:)
        config_path = config_path(directory.path)
        document = read_config_document(config_path)
        version = document.dig("runtime", "schema_version")
        return [:already_current, directory] if version == SCHEMA_VERSION

        ConfigRules.validate_schema_version!(document)

        backup = replace_config!(config_path, migrated_document(document))
        [:migrated, new(directory.path), backup]
      end

      # `tamoz setup` on an existing runtime is one edit; a written chat profile pins the workspace it was made for.
      def self.configure!(path, workspace:, models:, env: ENV)
        directory = resolve(path:, env:)
        moved = workspace && !directory.workspace?(workspace)
        if moved && directory.chat_profile?
          raise Error, "the workspace of #{directory.path} cannot change: its chat profile works in " \
                       "#{directory.workspace_root}"
        end
        require_workspace_directory!(workspace) if moved

        edit_config!(directory) do |document|
          document = document.merge('workspace' => { 'root' => File.expand_path(workspace) }) if moved
          models.empty? ? document : document.merge('models' => RuntimeModels.merge(document['models'], models))
        end
      end

      def database_path = File.join(path, DATABASE_FILE)
      def profiles_path = File.join(path, PROFILES_DIR)
      def attachment_spool = Tamoz::Core::AttachmentSpool.new(File.join(path, 'attachments'))
      def workspace_root = @config.dig("workspace", "root")
      def workspace?(path) = canonical(path) == canonical(workspace_root)
      def chat_profile_id = channels.values.first&.fetch('profile') || CHAT_PROFILE
      def chat_profile? = File.exist?(File.join(profiles_path, "#{chat_profile_id}.yaml"))

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

      def subagents = Array(@config.dig('harness', 'subagents'))

      # The deployed channel surfaces (COMMS_DESIGN §14): surface_id -> entry,
      # validated strictly at load against the closed kind list and the
      # mandatory revision/expected_bot_id fields. Deep field validation is
      # SurfaceDescriptor's contract; this is the fast, load-time gate.
      def channels
        raw = @config["channels"]
        return {}.freeze unless raw.is_a?(Hash)

        raw.each_with_object({}) do |(surface_id, entry), out|
          out[surface_id] = ConfigRules.validate_channel!(surface_id, entry)
        end.freeze
      end

      # Where operator-authored skills live: inside the runtime directory unless configured, and
      # never inside the workspace, refused here so a bad configuration fails before any turn.
      def skills_root
        configured = source_settings("skills")["root"]
        return File.join(path, "skills") if configured.nil?

        Tamoz::Skills.disjoint!(File.expand_path(configured, path), workspace_root)
      end

      def stream_bounds
        raw = @config["stream"]
        raw.is_a?(Hash) ? raw : {}
      end

      class << self
        private

        def config_path(path)
          File.join(path, CONFIG_FILE)
        end

        def ensure_private_runtime_directories!(path)
          Tamoz::Core::PrivateDirectory.secure(path)
          Tamoz::Core::PrivateDirectory.secure(File.join(path, PROFILES_DIR))
        end

        def write_default_config!(path, workspace:, models:)
          document = {
            "runtime" => {"schema_version" => SCHEMA_VERSION},
            "workspace" => {"root" => File.expand_path(workspace)},
            "sources" => {},
            "channels" => {}
          }
          document["models"] = models unless models.empty?
          Tamoz::Core::AtomicFile.create(config_path(path), Psych.dump(document), mode: 0o600)
        rescue Errno::EEXIST
          nil
        end

        def read_config_document(config_path)
          Psych.safe_load_file(config_path, permitted_classes: [], aliases: false)
        end

        def migrated_document(document)
          document.merge(
            "runtime" => {"schema_version" => SCHEMA_VERSION},
            "channels" => {}
          )
        end

        # The whole new document must validate before anything is written, so a refused edit leaves the file untouched.
        def replace_config!(config_path, document)
          ConfigRules.validate_document!(document)
          backup = backup_config!(config_path)
          write_migrated_config!(config_path, document)
          backup
        end

        def require_workspace_directory!(workspace)
          raise Error, "the workspace #{workspace} is not a directory" unless File.directory?(workspace)
        end

        def edit_config!(directory)
          config_path = config_path(directory.path)
          edited = yield(read_config_document(config_path))
          return directory if edited == read_config_document(config_path)

          replace_config!(config_path, edited)
          new(directory.path)
        end

        def backup_config!(config_path)
          backup = "#{config_path}.bak-#{Time.now.utc.strftime('%Y%m%dT%H%M%S.%6NZ')}"
          Tamoz::Core::AtomicFile.create(backup, File.binread(config_path), mode: 0o600)
          backup
        end

        def write_migrated_config!(config_path, document)
          Tamoz::Core::AtomicFile.replace(config_path, Psych.dump(document), mode: 0o600)
        end
      end

      private

      def canonical(path) = File.exist?(path) ? File.realpath(path) : File.expand_path(path)

      def load_config
        ensure_runtime_directory_available
        config_path = private_config_path
        document = read_config_document(config_path)
        raise Error, "runtime configuration must be a mapping" unless document.is_a?(Hash)

        ConfigRules.validate_document!(document)
        document.freeze
      end

      def ensure_runtime_directory_available
        unless File.directory?(path)
          raise Error, "runtime directory #{path} does not exist; run 'tamoz setup' first"
        end

        assert_private!(path, "runtime directory")
      end

      def private_config_path
        config_path = self.class.send(:config_path, path)
        raise Error, "#{config_path} does not exist; run 'tamoz setup' first" unless File.exist?(config_path)

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

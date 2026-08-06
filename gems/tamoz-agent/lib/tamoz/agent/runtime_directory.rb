# frozen_string_literal: true

require "psych"
require "fileutils"

module Tamoz
  module Agent
    # The operator-owned runtime directory: one place a worker is pointed at, and
    # the only place its authority comes from.
    #
    #   <runtime-dir>/
    #     config.yaml        operator configuration (workspace root, sources, bounds)
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
    class RuntimeDirectory
      class Error < Tamoz::Agent::Error; end

      CONFIG_FILE = "config.yaml"
      DATABASE_FILE = "runtime.sqlite3"
      PROFILES_DIR = "profiles"
      SCHEMA_VERSION = 1

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
        FileUtils.mkdir_p(path, mode: 0o700)
        File.chmod(0o700, path)
        FileUtils.mkdir_p(File.join(path, PROFILES_DIR), mode: 0o700)
        File.chmod(0o700, File.join(path, PROFILES_DIR))
        config_path = File.join(path, CONFIG_FILE)
        unless File.exist?(config_path)
          document = {
            "runtime" => {"schema_version" => SCHEMA_VERSION},
            "workspace" => {"root" => File.expand_path(workspace)},
            "sources" => {}
          }
          File.write(config_path, Psych.dump(document))
          File.chmod(0o600, config_path)
        end
        new(path)
      end

      def database_path = File.join(path, DATABASE_FILE)
      def profiles_path = File.join(path, PROFILES_DIR)
      def workspace_root = @config.dig("workspace", "root")

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

      private

      def load_config
        unless File.directory?(path)
          raise Error, "runtime directory #{path} does not exist; run 'tamoz init' first"
        end

        assert_private!(path, "runtime directory")
        config_path = File.join(path, CONFIG_FILE)
        raise Error, "#{config_path} does not exist; run 'tamoz init' first" unless File.exist?(config_path)

        assert_private!(config_path, "runtime configuration")
        document = begin
          Psych.safe_load_file(config_path, permitted_classes: [], aliases: false)
        rescue Psych::Exception => error
          raise Error, "runtime configuration is not valid YAML: #{error.message}"
        end
        raise Error, "runtime configuration must be a mapping" unless document.is_a?(Hash)

        version = document.dig("runtime", "schema_version")
        unless version == SCHEMA_VERSION
          raise Error, "runtime configuration schema_version #{version.inspect} " \
                       "is not supported (expected #{SCHEMA_VERSION})"
        end

        root = document.dig("workspace", "root")
        raise Error, "runtime configuration must set workspace.root" unless root.is_a?(String) && !root.empty?

        document.freeze
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

# frozen_string_literal: true

module Tamoz
  module Agent
    # C7 (PLAN_ADR049 Phase 6): exact per-command child environments. Every
    # child gets the standard runtime allowlist plus only the credentials its
    # command may hold: the gateway gets the bot token but never the model
    # key, the worker gets the model key but never the bot token, queue/status
    # get neither, and the harness gets only sanitized pointers. A value that
    # is not in the map never reaches the child — there is no shared-env path.
    #
    # The ALMS endpoint is deliberately NOT here: the worker resolves it from
    # the runtime config's MCP server entry (`sources.mcp.servers[alms].
    # endpoint`) the way every other MCP surface is resolved, so no child
    # needs it as an environment variable.
    module ChildEnvironments
      STANDARD = %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB].freeze
      GATEWAY_ONLY = %w[TAMOZ_TELEGRAM_BOT_TOKEN].freeze
      FORBIDDEN_EVERYWHERE = %w[TAMOZ_ENV_FILE].freeze

      def self.standard_env(base)
        STANDARD.filter_map { |name| [name, base[name]] }.to_h
      end

      def self.gateway_env(base, runtime_dir:, surface:)
        standard_env(base).merge(
          'TAMOZ_RUNTIME_DIR' => runtime_dir,
          'TAMOZ_TELEGRAM_SURFACE' => surface,
          'TAMOZ_TELEGRAM_BOT_TOKEN' => base.fetch('TAMOZ_TELEGRAM_BOT_TOKEN'),
          'TAMOZ_TELEGRAM_API_ORIGIN' => base['TAMOZ_TELEGRAM_API_ORIGIN']
        ).compact
      end

      # The worker alone validates provider credential selection; the
      # credential is named from the provider, never passed as a free string.
      def self.worker_env(base, runtime_dir:, profile_role: nil)
        provider = base.fetch('TAMOZ_PROVIDER')
        standard_env(base).merge(
          'TAMOZ_RUNTIME_DIR' => runtime_dir,
          'TAMOZ_PROVIDER' => provider,
          'TAMOZ_MODEL' => base.fetch('TAMOZ_MODEL')
        ).merge(
          ModelClientFactory.worker_environment(provider:, profile_role:, environment: base)
        )
      end

      def self.queue_status_env(base, runtime_dir:)
        standard_env(base).merge('TAMOZ_RUNTIME_DIR' => runtime_dir)
      end

      # :reek:LongParameterList -- the harness pointer set is exactly these
      # four sanitized values; a bundle object would hide the allowlist.
      def self.harness_env(base, runtime_dir:, database_path: nil)
        standard_env(base).merge('TAMOZ_RUNTIME_DIR' => runtime_dir).tap do |env|
          env['TAMOZ_DATABASE_PATH'] = database_path if database_path
        end
      end
    end
  end
end

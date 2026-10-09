# frozen_string_literal: true

module Tamoz
  module Agent
    # C7 (PLAN_ADR049 Phase 6): exact per-command child environments. Every
    # child gets the standard runtime allowlist plus only the credentials its
    # command may hold: the gateway gets its channel token (and, for talk, the
    # voice key) but never the chat model key, the worker gets its models' and
    # sources' keys but never a channel token, queue/status
    # get neither, and the harness gets only sanitized pointers. A value that
    # is not in the map never reaches the child — there is no shared-env path.
    #
    # The ALMS endpoint is deliberately NOT here: the worker resolves it from
    # the runtime config's MCP server entry (`sources.mcp.servers[alms].
    # endpoint`) the way every other MCP surface is resolved, so no child
    # needs it as an environment variable.
    module ChildEnvironments
      STANDARD = %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB].freeze
      CHANNEL_TOKENS = %w[TAMOZ_TELEGRAM_BOT_TOKEN TAMOZ_TALK_TOKEN].freeze
      FORBIDDEN_EVERYWHERE = %w[TAMOZ_ENV_FILE].freeze

      def self.standard_env(base)
        STANDARD.filter_map { |name| [name, base[name]] }.to_h
      end

      def self.gateway_env(base, directory:, surface:)
        return talk_gateway_env(base, directory:) if directory.channels.fetch(surface)['kind'] == 'talk'

        standard_env(base).merge(
          'TAMOZ_RUNTIME_DIR' => directory.path,
          'TAMOZ_TELEGRAM_SURFACE' => surface,
          'TAMOZ_TELEGRAM_BOT_TOKEN' => base.fetch('TAMOZ_TELEGRAM_BOT_TOKEN'),
          'TAMOZ_TELEGRAM_API_ORIGIN' => base['TAMOZ_TELEGRAM_API_ORIGIN']
        ).compact
      end

      # The talk gateway holds its access token and the one presentation key, the voice role's (ADR-042).
      def self.talk_gateway_env(base, directory:)
        standard_env(base).merge(
          'TAMOZ_RUNTIME_DIR' => directory.path, 'TAMOZ_TALK_TOKEN' => base.fetch('TAMOZ_TALK_TOKEN'),
          'TAMOZ_TALK_HOST' => base['TAMOZ_TALK_HOST'], 'TAMOZ_TALK_TRACE' => base['TAMOZ_TALK_TRACE']
        ).compact.merge(model_keys(base, directory.models['voice']))
      end

      # The worker's models and sources come from the runtime config; it holds their keys and never a channel token.
      def self.worker_env(base, directory:)
        models = directory.models
        base.slice(*directory.source_variables).except(*CHANNEL_TOKENS, *FORBIDDEN_EVERYWHERE)
            .merge(standard_env(base), 'TAMOZ_RUNTIME_DIR' => directory.path)
            .merge(*%w[chat transcription vision].map { |role| model_keys(base, models[role]) })
      end

      def self.model_keys(base, model)
        return {} unless model

        ModelClientFactory.worker_environment(provider: model.provider, environment: base,
                                              credential_name: model.credential)
      end

      def self.role_credential(base, role)
        name = base["TAMOZ_#{role}_CREDENTIAL"]
        return nil if name.to_s.empty?

        return name if ModelClientFactory.role_credential?(name)

        raise ArgumentError, "TAMOZ_#{role}_CREDENTIAL must name an *_API_KEY variable, never a runtime or channel one"
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

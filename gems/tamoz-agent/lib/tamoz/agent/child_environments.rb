# frozen_string_literal: true

module Tamoz
  module Agent
    # Each child's exact environment: a gateway only its kind's declared variables (and, when it speaks, the voice
    # key); the worker its models' and sources' keys but never a channel variable.
    module ChildEnvironments
      STANDARD = %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB].freeze
      FORBIDDEN_EVERYWHERE = %w[TAMOZ_ENV_FILE].freeze
      MODEL_ROLES = %w[chat transcription vision].freeze

      class Error < Tamoz::Agent::Error; end

      def self.standard_env(base)
        STANDARD.filter_map { |name| [name, base[name]] }.to_h
      end

      # @param vars [Hash] what the surface's channel setup hands its gateway; @param allowed [Array<String>] the
      #   variable names that kind declares; any other name is refused, not dropped.
      def self.gateway_env(base, directory:, vars:, allowed:, speech:)
        refuse_foreign!(base, directory, vars, allowed)
        standard_env(base).merge('TAMOZ_RUNTIME_DIR' => directory.path).merge(vars.compact)
                          .merge(speech ? model_keys(base, directory.models['voice']) : {})
      end

      def self.refuse_foreign!(base, directory, vars, allowed)
        foreign = vars.keys - allowed
        unless foreign.empty?
          raise Error,
                "a channel handed its gateway #{foreign.join(', ')}, which it does not declare"
        end

        held = vars.keys & (FORBIDDEN_EVERYWHERE + MODEL_ROLES.flat_map do |role|
          model_keys(base, directory.models[role]).keys
        end)
        raise Error, "a channel's gateway may not hold #{held.join(', ')}" unless held.empty?
      end

      # The worker's models and sources come from the runtime config; it never holds a channel variable, even one a
      # model's key is named after (`start` refuses that configuration).
      def self.worker_env(base, directory:, channel_names:)
        models = directory.models
        base.slice(*directory.source_variables).merge(standard_env(base), 'TAMOZ_RUNTIME_DIR' => directory.path)
            .merge(*MODEL_ROLES.map { |role| model_keys(base, models[role]) })
            .except(*channel_names, *FORBIDDEN_EVERYWHERE)
      end

      def self.model_keys(base, model)
        return {} unless model

        ModelClientFactory.worker_environment(provider: model.provider, environment: base,
                                              credential_name: model.credential)
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

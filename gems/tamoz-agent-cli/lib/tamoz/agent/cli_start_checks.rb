# frozen_string_literal: true

module Tamoz
  module Agent
    # What `tamoz start` proves before it runs anything: one real call per model, and no other run on a channel.
    module CLIStartChecks
      REFUSALS = { 401 => 'the API key was rejected', 403 => 'the API key was rejected',
                   402 => 'the account is out of credit', 429 => 'the key is rate-limited right now' }.freeze
      NO_HEARING = 'a channel that speaks needs a speech-to-text model; set one with ' \
                   '`tamoz setup --transcription PROVIDER/MODEL`'

      private

      # A second gateway on the same channel loses the poller race and exits; name the run that owns it instead.
      # A lease left by a run that crashed expires within a minute, so that case waits it out.
      def already_running(options, descriptor)
        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          state = lease_state(store, descriptor)
          remaining = (state['poller_expires_at_ms'].to_i / 1000.0) - Time.now.to_f
          pid = state['poller_owner_id'].to_s[/\A#{CLICommsShared::GATEWAY_POLLER_PREFIX}:(\d+)\z/o, 1]&.to_i
          next unless remaining.positive? && pid
          if alive?(pid)
            next "Tamoz is already running for this channel (pid #{pid}); stop it first (Ctrl-C where it runs)"
          end

          @out.puts "Waiting #{remaining.ceil}s for the previous run's hold on the channel to expire..."
          sleep(remaining)
          nil
        end
      end

      def lease_state(store, descriptor)
        store.poll_state(stream_id: descriptor.identity.fetch(:stream_id)) || {}
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def chat_problem(directory, base)
        chat = directory.models['chat']
        problem = provider_problem(chat.provider, chat.model, base)
        return unless problem

        "the chat model #{chat.provider}/#{chat.model} (#{Providers::ENV_KEYS[chat.provider.to_sym]}): #{problem}"
      end

      def provider_problem(provider, model, base)
        client = @model_factory&.call(provider:, model:) ||
                 ModelClientFactory.build(provider:, model:, profile_role: nil, environment: base, safety: :idempotent)
        client.generate(stage: :ping, system: 'Reply with the single word ok.', prompt: 'ping')
        nil
      rescue ModelCallError => e
        return "no #{Providers::ENV_KEYS[provider.to_sym]} found; set it" if e.code == 'credential_unavailable'

        REFUSALS.fetch(e.status.to_i) { "the provider call failed (#{e.code})" }
      rescue StandardError => e
        "the provider could not be reached (#{e.class})"
      end

      # A speaking surface's gateway holds the voice key, so the voice key must never be the chat model's.
      def voice_key_problem(directory, base)
        voice = directory.models['voice']
        return unless voice

        voice_key = voice.credential || Providers::ENV_KEYS[voice.provider.to_sym]
        chat_key = Providers::ENV_KEYS[directory.models['chat'].provider.to_sym]
        return unless voice_key == chat_key || (!base[voice_key].to_s.empty? && base[voice_key] == base[chat_key])

        "the voice key (#{voice_key}) must not be the chat model's key (#{chat_key}); give speech its own key"
      end

      def speech_models_problem(directory, base)
        return NO_HEARING unless directory.models['transcription']

        voice_key_problem(directory, base)
      end

      # The worker drops every channel variable, so a model whose key is named like one would fail without a word.
      def channel_named_model_key(directory)
        names = channel_names(directory)
        role = %w[chat transcription vision voice].find do |name|
          model = directory.models[name]
          model && names.include?(model.credential || Providers::ENV_KEYS[model.provider.to_sym])
        end
        "the #{role} model's key is named like a channel variable; give it its own name" if role
      end

      def warn_voice(directory, base)
        problem = voice_problem(directory, base)
        @err.puts "tamoz: #{problem}; replies are text only until it answers" if problem
      end

      def transcription_problem(directory, base)
        model = role_model(base, 'TRANSCRIPTION', directory)
        return unless model

        model.transcribe(audio: silent_wav, filename: 'probe.wav', media_type: 'audio/wav')
        nil
      rescue ModelCallError, EffectUnknownError => e
        "the speech-to-text model did not answer (#{e.class.name.split('::').last}); check its key and credit"
      rescue ArgumentError, ConfigurationError => e
        e.message
      end

      def voice_problem(directory, base)
        voice = directory.models['voice']
        return unless voice

        role_model(base, 'VOICE', directory).speak(text: 'ok', voice: voice.voice)
        nil
      rescue ModelCallError, EffectUnknownError => e
        "the voice model did not answer (#{e.class.name.split('::').last})"
      end

      def role_model(base, role, directory) = attachment_model(role, runtime: directory, environment: base)

      def silent_wav
        samples = "\x00\x00".b * 16_000
        "RIFF#{[36 + samples.bytesize].pack('V')}WAVEfmt #{[16, 1, 1, 16_000, 32_000, 2, 16].pack('VvvVVvv')}" \
        "data#{[samples.bytesize].pack('V')}".b + samples
      end
    end
  end
end

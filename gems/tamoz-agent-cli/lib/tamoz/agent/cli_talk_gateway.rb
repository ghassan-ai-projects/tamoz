# frozen_string_literal: true

module Tamoz
  module Agent
    # The talk gateway process's half: one hub per talk surface, and the voice it speaks replies in.
    module CLITalkGateway
      # One hub per talk surface, shared by its poller and drainer transports.
      def talk_hub(descriptor, store, directory)
        @talk_hubs ||= {}
        @talk_hubs[descriptor.surface_id] ||= begin
          begin
            require 'tamoz/talk'
          rescue LoadError
            raise CLICommsShared::MissingAdapterError, 'the talk channel (tamoz-talk) is not installed'
          end
          hub = Tamoz::Talk::Hub.new(
            descriptor:, token: credential(descriptor), synthesize: voice_synthesizer(directory),
            floor: store.poll_offset(bot_id: descriptor.identity.fetch(:expected_bot_id)).to_i,
            host: @env.to_h.fetch('TAMOZ_TALK_HOST', '127.0.0.1'), trace: @env.to_h['TAMOZ_TALK_TRACE'] == '1'
          )
          hub.seed(store.delivered_messages(surface_id: descriptor.surface_id, limit: 50))
          hub
        end
      end

      def talk_hubs = (@talk_hubs || {}).values

      private

      # A voice that cannot be built (its key is missing) leaves the page text only; `start` has said so.
      def voice_synthesizer(directory)
        voice = directory.models['voice']
        model = voice && attachment_model('VOICE', runtime: directory)
        model && ->(text) { model.speak(text:, voice: voice.voice).audio }
      rescue ModelCallError, ConfigurationError
        nil
      end
    end
  end
end

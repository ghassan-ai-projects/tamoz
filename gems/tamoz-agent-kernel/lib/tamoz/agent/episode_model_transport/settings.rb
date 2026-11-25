# frozen_string_literal: true

module Tamoz
  module Agent
    class EpisodeModelTransport
      # The frozen request settings, plus the optional reasoning effort a route may ask for.
      module Settings
        # The frozen request settings (P1 contract). The settings digest the
        # gateway signs and the receipt carries is computed over THIS document.
        REQUEST = {
          'temperature' => 0,
          'stream' => false,
          'response_format' => { 'type' => 'json_object' }
        }.freeze
        # The tool-calling request settings. A conversation carries native tool
        # calls, so it never asks for JSON mode.
        CONVERSATION = { 'temperature' => 0, 'stream' => false }.freeze

        module_function

        def request(effort) = with_effort(REQUEST, effort)

        def conversation(effort) = with_effort(CONVERSATION, effort)

        def with_effort(settings, effort) = effort ? settings.merge('reasoning_effort' => effort) : settings

        def effort(value)
          return nil if value.nil?
          return value.to_s if Providers::REASONING_EFFORTS.include?(value.to_s)

          raise ConfigurationError, "reasoning_effort must be one of #{Providers::REASONING_EFFORTS.join(', ')}"
        end
      end
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Agent
    class EpisodeModelTransport
      # One model answer as received, with the digests binding it; finish_reason is the provider's, empty when unknown.
      Response = Data.define(
        :content, :request_digest, :response_digest, :usage, :settings_digest,
        :provider_configuration_digest, :provider_retries, :finish_reason
      ) do
        def initialize(finish_reason: '', **fields) = super
      end
    end
  end
end

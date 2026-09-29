# frozen_string_literal: true

require 'json'
require 'uri'

module Tamoz
  module Mcp
    module Websearch
      # Brave web search through the governed egress client. The endpoint is fixed here, so no configuration can
      # point a search at another host, and the credential is the one named ref below.
      # :reek:TooManyStatements :reek:UtilityFunction
      class BraveSearch
        HOST = 'api.search.brave.com'
        PATH = '/res/v1/web/search'
        CREDENTIAL = 'TAMOZ_BRAVE_API_KEY'
        MAX_RESULTS = 10

        def initialize(client:, token:)
          unless client.policy.allowlisted_host?(HOST)
            raise ValidationError, "the egress declaration must allowlist #{HOST} for Brave search"
          end
          raise ValidationError, "Brave search needs #{CREDENTIAL}" if token.to_s.empty?
          unless client.policy.credential_refs.include?(CREDENTIAL)
            raise ValidationError, "the egress declaration must name #{CREDENTIAL} in credential_refs"
          end

          @client = client
          @token = token
          freeze
        end

        # [{"title", "url", "snippet", "age"}], at most `count` (clamped to 1..10).
        def search(query, count)
          params = URI.encode_www_form(q: query, count: count.clamp(1, MAX_RESULTS), result_filter: 'web',
                                       text_decorations: false)
          result = @client.fetch("https://#{HOST}#{PATH}?#{params}",
                                 headers: { 'X-Subscription-Token' => @token, 'Accept' => 'application/json' })
          status = result.status
          raise EgressPolicyError, "Brave search answered HTTP #{status}" unless status == 200
          raise EgressPolicyError, 'Brave search response exceeded the response bound' if result.truncated

          results(result.body)
        end

        private

        def results(body)
          web = JSON.parse(body).fetch('web', {})
          Array(web['results']).map do |item|
            { 'title' => plain(item['title']), 'url' => item['url'].to_s, 'snippet' => plain(item['description']),
              'age' => plain(item['page_age'] || item['age']) }
          end
        rescue JSON::ParserError
          raise EgressPolicyError, 'Brave search returned unreadable JSON'
        end

        def plain(text) = text.to_s.gsub(/<[^>]*>/, '').gsub(/\s+/, ' ').strip
      end
    end
  end
end

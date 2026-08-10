# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'

module Tamoz
  module OTel
    class HTTPExporter
      include Tamoz::Observability::Exporter

      attr_reader :policy

      def initialize(policy:, env: ENV)
        @policy = policy
        @env = env
        @headers = {}
        @opened = false
      end

      def open(descriptor = {}, credential = policy.credential_ref)
        @headers = credential_headers(credential)
        @descriptor = descriptor.dup.freeze
        @opened = true
        :opened
      rescue StandardError
        :rejected
      end

      def export(batch, deadline_ms: policy.timeout_ms)
        return :rejected unless @opened
        return :rejected unless batch.is_a?(Array) && batch.length <= policy.max_batch
        return :rejected if proxy_configured?

        body = JSON.generate(resource_spans(batch))
        return :rejected if body.bytesize > 16 * 1_024 * 1_024

        request = Net::HTTP::Post.new(policy.uri.request_uri)
        request['Content-Type'] = 'application/json'
        @headers.each { |name, value| request[name] = value }
        request.body = body
        http = Net::HTTP.new(policy.uri.host, policy.uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        timeout = [Float(deadline_ms) / 1_000, policy.timeout_ms / 1_000.0].min
        return :rejected unless timeout.positive?

        http.open_timeout = timeout
        http.read_timeout = timeout
        response = http.start { |connection| connection.request(request) }
        case response
        when Net::HTTPSuccess then :delivered
        when Net::HTTPTooManyRequests then :throttled
        when Net::HTTPRedirection then :rejected
        else :unknown
        end
      rescue StandardError
        :unknown
      end

      def close(deadline_ms: policy.timeout_ms)
        @opened = false
        :closed
      end

      private

      def credential_headers(credential)
        return {} if credential.nil?

        value = @env.fetch(credential.fetch('name'))
        raise Tamoz::Observability::ValidationError, 'OTLP credential is empty' if value.to_s.empty?
        raise Tamoz::Observability::ValidationError, 'OTLP credential contains a newline' if value.match?(/[\r\n]/)

        {'Authorization' => value.to_s}
      rescue KeyError
        raise Tamoz::Observability::ValidationError, 'OTLP credential is not available'
      end

      def proxy_configured?
        %w[HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy].any? do |name|
          !@env[name].to_s.empty?
        end
      end

      def resource_spans(batch)
        spans = batch.map do |item|
          document = item.respond_to?(:to_h) ? item.to_h : item
          correlation = value(document, 'correlation') || {}
          attributes = value(document, 'attributes') || {}
          observed_at_ms = value(document, 'observed_at_ms')
          name = value(document, 'name')
          trace_id = value(correlation, 'trace_id') || derived_trace_id(correlation)
          anchor = value(attributes, 'span_anchor') || value(correlation, 'effect_key') || observed_at_ms
          span_id = value(attributes, 'span_id') || derived_span_id(trace_id, name, anchor)
          started_at_ms = value(document, 'started_at_ms')
          ended_at_ms = value(document, 'ended_at_ms')
          {
            'name' => name,
            'trace_id' => trace_id,
            'span_id' => span_id,
            'kind' => value(document, 'kind'),
            'start_time_unix_nano' => started_at_ms && Integer(started_at_ms * 1_000_000),
            'end_time_unix_nano' => ended_at_ms && Integer(ended_at_ms * 1_000_000),
            'attributes' => attributes
          }.compact
        end
        {'resourceSpans' => [{'resource' => {'attributes' => @descriptor || {}}, 'scopeSpans' => [{'spans' => spans}]}]}
      end

      def value(document, key)
        document[key] || document[key.to_sym]
      end

      def derived_trace_id(correlation)
        thread_id = value(correlation, 'thread_id')
        execution_id = value(correlation, 'execution_id')
        return unless thread_id && execution_id

        Tamoz::Observability::Correlation.trace_id(thread_id:, execution_id:)
      end

      def derived_span_id(trace_id, name, anchor)
        return unless trace_id && anchor

        Tamoz::Observability::Correlation.span_id(trace_id:, kind: name, anchor:)
      end
    end
  end
end

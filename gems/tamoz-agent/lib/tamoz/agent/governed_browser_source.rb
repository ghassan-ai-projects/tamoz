# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # Adapter contract for a governed browser. Tamoz owns admission, URL
    # policy, output bounds, approval classification, and untrusted provenance;
    # a browser connector owns tabs and transport. With no connector, execution
    # refuses before any network or browser action.
    class GovernedBrowserSource
      MAX_URL_BYTES = 2 * 1024
      MAX_OUTPUT_BYTES = 64 * 1024
      URL_PATTERN = %r{\Ahttps://([^/]+)(?:/.*)?\z}

      Observation = Data.define(:text, :server_id, :truncated)
      Outcome = Data.define(:status, :observation, :interrupt, :denial)

      def initialize(adapter:, descriptors:, allowed_hosts:)
        @adapter = adapter
        @descriptors = descriptors.freeze
        @allowed_hosts = allowed_hosts.map { |host| String(host).downcase }.freeze
        raise ArgumentError, 'browser source requires an exact host allowlist' if @allowed_hosts.empty?

        @index = @descriptors.to_h { |descriptor| [descriptor.id, descriptor] }.freeze
        @names = @index.keys.freeze
        freeze
      end

      attr_reader :descriptors, :names

      def name?(name) = @index.key?(String(name))
      def descriptor_for(name) = @index.fetch(String(name))
      def read_only?(name) = descriptor_for(name).effect_class.to_sym == :read_only
      def approval_required?(name) = !read_only?(name)
      def maximum_effect_output_bytes(_name) = MAX_OUTPUT_BYTES
      def effect_intent(_name, arguments) = { 'arguments_digest' => Tamoz::Core.digest("tamoz.browser.arguments.v1\n", validate_arguments(arguments)) }

      def validate(name, arguments)
        descriptor_for(name)
        validate_arguments(arguments)
      end

      def preview(name, arguments)
        "Browser #{name}\narguments: #{JSON.generate(Tamoz::Core.canonical(validate_arguments(arguments)))}"
      end

      def execute(context, name, arguments)
        descriptor_for(name)
        normalized = validate_arguments(arguments)
        raise ToolError, 'browser adapter unavailable: configure an approved browser connector' unless
          @adapter.respond_to?(:execute)

        raw = @adapter.execute(context:, capability_id: String(name), arguments: normalized)
        validate_final_location!(raw)
        status = adapter_status(raw)
        text = raw.is_a?(Hash) ? raw.fetch('output', raw.fetch('text', '')) : raw.to_s
        truncated = text.bytesize > MAX_OUTPUT_BYTES
        observation = Observation.new(
          text: text.byteslice(0, MAX_OUTPUT_BYTES), server_id: 'browser', truncated:
        )
        case status
        when :succeeded
          Outcome.new(status:, observation:, interrupt: nil, denial: nil)
        when :denied
          Outcome.new(status:, observation:, interrupt: nil, denial: adapter_reason(raw))
        when :interrupt
          Outcome.new(status:, observation:, interrupt: adapter_reason(raw), denial: nil)
        when :failed, :unknown
          Outcome.new(status:, observation:, interrupt: nil, denial: adapter_reason(raw))
        else
          raise ToolError, "browser adapter returned unsupported outcome #{status.inspect}"
        end
      end

      def close = @adapter&.close

      private

      def validate_arguments(arguments)
        raise ToolArgumentError, 'browser arguments must be an object' unless arguments.is_a?(Hash)
        raise Tamoz::SensitiveValueError, 'browser arguments cannot contain credential-shaped values' if
          Tamoz::Core.secret_shaped?(arguments)

        url = arguments['url']
        return arguments unless url
        raise ToolArgumentError, 'browser url must be a bounded string' unless
          url.is_a?(String) && url.bytesize <= MAX_URL_BYTES

        match = URL_PATTERN.match(url)
        raise ToolPolicyError, 'browser permits HTTPS URLs only' unless match

        host = match[1].downcase
        raise ToolPolicyError, 'browser host is not allowlisted' unless @allowed_hosts.include?(host)

        arguments
      end

      def adapter_status(raw)
        return :succeeded unless raw.is_a?(Hash) && raw.key?('status')

        status = raw.fetch('status').to_s.downcase.to_sym
        return status if %i[succeeded failed unknown denied interrupt].include?(status)

        :unknown
      end

      def adapter_reason(raw)
        value = if raw.is_a?(Hash)
                  raw['reason'] || raw['error'] || raw['message'] || raw['denial']
                end
        text = value.to_s
        { 'reason' => text.byteslice(0, 512) || '' }.freeze
      end

      def validate_final_location!(raw)
        return unless raw.is_a?(Hash)

        evidence = raw.fetch('evidence', {})
        unless evidence.is_a?(Hash)
          raise ToolPolicyError, 'browser adapter location evidence must be an object'
        end

        final_url = raw.key?('final_url') ? raw['final_url'] : evidence['final_url']
        final_host = raw.key?('final_host') ? raw['final_host'] : evidence['final_host']
        return if final_url.nil? && final_host.nil?

        url_host = validate_location_url(final_url) if final_url
        evidence_host = validate_location_host(final_host) if final_host
        if url_host && evidence_host && url_host != evidence_host
          raise ToolPolicyError, 'browser adapter final URL and host evidence disagree'
        end
      end

      def validate_location_url(url)
        unless url.is_a?(String) && url.bytesize <= MAX_URL_BYTES
          raise ToolPolicyError, 'browser adapter final URL is not bounded'
        end

        match = URL_PATTERN.match(url)
        raise ToolPolicyError, 'browser adapter final URL must use HTTPS' unless match

        validate_location_host(match[1])
      end

      def validate_location_host(host)
        unless host.is_a?(String) && host.bytesize <= MAX_URL_BYTES
          raise ToolPolicyError, 'browser adapter final host is not bounded'
        end

        normalized = host.downcase
        raise ToolPolicyError, 'browser adapter final host is not allowlisted' unless
          @allowed_hosts.include?(normalized)

        normalized
      end
    end
  end
end

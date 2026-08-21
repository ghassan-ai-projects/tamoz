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
        text = raw.is_a?(Hash) ? raw.fetch('output', raw.fetch('text', '')) : raw.to_s
        truncated = text.bytesize > MAX_OUTPUT_BYTES
        observation = Observation.new(
          text: text.byteslice(0, MAX_OUTPUT_BYTES), server_id: 'browser', truncated:
        )
        Outcome.new(status: :succeeded, observation:, interrupt: nil, denial: nil)
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
    end
  end
end

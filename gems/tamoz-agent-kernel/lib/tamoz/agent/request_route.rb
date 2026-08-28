# frozen_string_literal: true

module Tamoz
  module Agent
    RequestRoute = Data.define(:name, :answer, :reason_class, :plan) do
      NAMES = %w[direct_response read_only_work managed_action].freeze
      REASON_CLASSES = %w[
        greeting general_knowledge explanation writing
        workspace_evidence current_external_state requested_change
        command_or_code action_result ambiguous_context
      ].freeze
      DIRECT_REASON_CLASSES = %w[greeting general_knowledge explanation writing].freeze
      UNSAFE_DIRECT_PATTERNS = [
        /\b(?:workspace|file|directory|folder|path|repository|repo|code|source)\b/i,
        /\b(?:read|inspect|list|search|find|diagnos|debug|trace)\w*/i,
        /\b(?:edit|change|modify|update|delete|remove|fix|implement|run|execute)\w*/i,
        /\b(?:script|command|configuration|config|setting|settings)\b/i,
        /\b(?:current|latest|today|now|weather|stock|internet|web)\b/i,
        /\b(?:pretend|without doing|say .*done)\b/i,
        /\A\s*(?:what about|and|also)\b/i
      ].freeze

      def self.parse(value)
        document = Tamoz::Core.parse_object(value)
        reject_unknown_keys(document)
        name = required_string(document, 'route')
        raise ProtocolError, "unknown route #{name.inspect}" unless NAMES.include?(name)

        reason_class = required_string(document, 'reason_class')
        unless REASON_CLASSES.include?(reason_class)
          raise ProtocolError, "unknown route reason class #{reason_class.inspect}"
        end

        if name == 'direct_response'
          parse_direct(document, reason_class)
        else
          parse_work(document, name, reason_class)
        end
      rescue KeyError, TypeError => e
        raise ProtocolError, "invalid route: #{e.message}"
      end

      def direct_response? = name == 'direct_response'
      def work? = !direct_response?

      def self.self_contained_task?(task)
        UNSAFE_DIRECT_PATTERNS.none? { |pattern| pattern.match?(String(task)) }
      end

      def self.direct_chat_candidate?(task)
        text = String(task).strip
        return false unless self_contained_task?(text)

        text.split(/\s+/).length == 1 || text.end_with?('?')
      end

      class << self
        private

        def reject_unknown_keys(document)
          unknown = document.keys.map(&:to_s) - %w[route answer reason_class discovery_plan]
          return if unknown.empty?

          raise ProtocolError, "route contains unknown fields: #{unknown.sort.join(', ')}"
        end

        def required_string(document, key)
          value = document.fetch(key)
          raise ProtocolError, "route #{key} must be a string" unless value.is_a?(String)
          raise ProtocolError, "route #{key} must not be empty" if value.strip.empty?

          value
        end

        def parse_direct(document, reason_class)
          unless DIRECT_REASON_CLASSES.include?(reason_class)
            raise ProtocolError, 'direct response reason class is not eligible'
          end

          answer = required_string(document, 'answer')
          raise ProtocolError, 'direct response cannot include a discovery plan' if document.key?('discovery_plan')

          new(name: 'direct_response', answer:, reason_class:, plan: nil).freeze
        end

        def parse_work(document, name, reason_class)
          raise ProtocolError, 'work route cannot include an answer' if document.key?('answer')

          plan = Plan.parse(document.fetch('discovery_plan'))
          new(name:, answer: nil, reason_class:, plan:).freeze
        end
      end
    end

    RoutingDecision = Data.define(:route, :answer, :reason_class, :plan, :fallback) do
      def self.from(request, toolbox:)
        route = request.name
        fallback = nil
        if route == 'managed_action' && !toolbox.action_capable?
          route = 'read_only_work'
          fallback = 'action_capability_unavailable'
        end
        new(route:, answer: request.answer, reason_class: request.reason_class,
            plan: request.plan, fallback:).freeze
      end

      def direct_response? = route == 'direct_response'
    end
  end
end

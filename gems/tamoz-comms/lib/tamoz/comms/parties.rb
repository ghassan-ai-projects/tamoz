# frozen_string_literal: true

require_relative 'errors'

module Tamoz
  module Comms
    # What differs per surface kind: identity prefixes, the thread prefix, and whether
    # the worker's "Heard" notice is delivered. Telegram's entry is byte-identical to the literals it replaced.
    module Parties
      Kind = Data.define(:name, :correspondent, :admissible, :bindable, :refused_groups, :thread_prefix,
                         :heard_notice)

      KINDS = {
        'telegram' => Kind.new(
          name: 'telegram', correspondent: 'telegram:user:',
          admissible: %w[telegram:chat: telegram:group: telegram:supergroup: telegram:channel:],
          bindable: %w[telegram:chat:], refused_groups: %w[telegram:supergroup: telegram:channel: telegram:group:],
          thread_prefix: 'tg.', heard_notice: false
        ),
        'talk' => Kind.new(
          name: 'talk', correspondent: 'talk:user:', admissible: %w[talk:chat:], bindable: %w[talk:chat:],
          refused_groups: [], thread_prefix: 'tk.', heard_notice: true
        )
      }.freeze

      module_function

      def of_correspondent(id) = KINDS.values.find { |kind| id.to_s.start_with?(kind.correspondent) }

      def of_conversation(id) = KINDS.values.find { |kind| id.to_s.start_with?(*kind.admissible) }

      def correspondent_prefixes = KINDS.values.map(&:correspondent)

      def admissible_prefixes = KINDS.values.flat_map(&:admissible)

      def bindable_prefixes = KINDS.values.flat_map(&:bindable)

      def group_chat?(conversation_id)
        kind = of_conversation(conversation_id)
        kind ? conversation_id.start_with?(*kind.refused_groups) : false
      end

      # Both parties belong to one kind, and it is the surface's.
      def same_kind?(correspondent_id, conversation_id, surface_kind)
        of_correspondent(correspondent_id)&.name == surface_kind && of_conversation(conversation_id)&.name == surface_kind
      end
    end
  end
end

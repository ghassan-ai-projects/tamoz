# frozen_string_literal: true

require_relative 'errors'

module Tamoz
  module Comms
    # One grammar for every channel's party ids: a correspondent is `<kind>:user:<id>`, a conversation
    # `<kind>:<space>:<id>`. Only a `chat` binds; every other space is a group chat, which admission refuses.
    module Parties
      PARTY = /\A([a-z][a-z0-9_]{1,31}):(user|chat|group|supergroup|channel):(-?[0-9]{1,20})\z/
      Party = Data.define(:kind, :space, :id)

      module_function

      def parse(id)
        match = PARTY.match(id.to_s)
        return unless match && SurfaceDescriptor.valid_kind?(match[1])

        Party.new(kind: match[1], space: match[2], id: match[3])
      end

      def correspondent?(id) = parse(id)&.space == 'user'

      def conversation?(id) = !parse(id).nil? && !correspondent?(id)

      def bindable?(id) = parse(id)&.space == 'chat'

      def group_chat?(id) = conversation?(id) && !bindable?(id)

      def kind_of(id) = parse(id)&.kind

      # Both parties belong to one kind, and it is the surface's.
      def same_kind?(correspondent_id, conversation_id, surface_kind)
        correspondent?(correspondent_id) && conversation?(conversation_id) &&
          kind_of(correspondent_id) == surface_kind && kind_of(conversation_id) == surface_kind
      end
    end
  end
end

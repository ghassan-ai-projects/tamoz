# frozen_string_literal: true

require 'time'

require_relative 'errors'
require_relative 'shapes'
require_relative 'surface_descriptor'

module Tamoz
  module Comms
    Binding = Data.define(:surface_id, :surface_revision, :correspondent_id, :conversation_id,
                          :status, :bound_at, :bound_by, :version, :revocation_reason)

    # One approved correspondent binding under a surface revision (design §7).
    # A binding is versioned and revocable: each approved binding has its own
    # id/version, actor, timestamp and revocation status, scoped to one surface
    # revision, and is recorded on every admission. Usernames and display names
    # never appear — only numeric ids.
    # :reek:MissingSafeMethod, :reek:NilCheck
    class Binding
      STATUSES = %w[active revoked].freeze
      MAX_ID_BYTES = 256
      DEFAULTS = { status: 'active', version: 1, revocation_reason: nil }.freeze

      def initialize(bound_at:, **fields)
        super(**DEFAULTS, **fields, bound_at: Shapes.utc(bound_at))
        validate!
      end

      def active? = status == 'active'

      def revoked? = status == 'revoked'

      def wire = to_h.transform_keys(&:to_s).merge('bound_at' => bound_at.iso8601(6))

      def self.from_wire(wire)
        new(**members.to_h { |name| [name, wire[name.to_s]] }, bound_at: Time.parse(wire.fetch('bound_at')))
      end

      private

      def validate!
        Shapes.require_string!(surface_id, 'surface_id', max_bytes: MAX_ID_BYTES)
        Shapes.require_positive!(surface_revision, 'surface_revision')
        validate_parties!
        Shapes.require_member!(status, STATUSES, 'status')
        Shapes.require_time!(bound_at, 'bound_at')
        Shapes.require_string!(bound_by, 'bound_by', max_bytes: MAX_ID_BYTES)
        Shapes.require_positive!(version, 'version')
        return unless revoked? && revocation_reason.nil?

        raise ValidationError, 'a revoked binding needs a revocation_reason'
      end

      def validate_parties!
        unless Parties.correspondent?(correspondent_id)
          raise ValidationError,
                'correspondent_id must be a bound user id'
        end
        raise ValidationError, 'conversation_id must be a bound chat id' unless Parties.bindable?(conversation_id)
        return if Parties.kind_of(correspondent_id) == Parties.kind_of(conversation_id)

        raise ValidationError, 'a binding pairs a user and a chat of one surface kind'
      end
    end
  end
end

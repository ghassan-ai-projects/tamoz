# frozen_string_literal: true

require 'time'

require_relative 'errors'
require_relative 'shapes'
require_relative 'surface_descriptor'

module Tamoz
  module Comms
    # One approved correspondent binding under a surface revision (design §7).
    # A binding is versioned and revocable: each approved binding has its own
    # id/version, actor, timestamp and revocation status, scoped to one surface
    # revision, and is recorded on every admission. Usernames and display names
    # never appear — only numeric telegram ids.
    #
    # The binding's fields ARE the value and its validation is the per-field
    # rule set; splitting either would fragment the row the store persists.
    # :reek:LongParameterList, :reek:MissingSafeMethod, :reek:TooManyInstanceVariables
    # :reek:TooManyStatements, :reek:NilCheck
    class Binding
      STATUSES = %w[active revoked].freeze
      MAX_ID_BYTES = 256

      attr_reader :surface_id, :surface_revision, :correspondent_id,
                  :conversation_id, :status, :bound_at, :bound_by, :version,
                  :revocation_reason

      def initialize( # rubocop:disable Metrics/ParameterLists
        surface_id:, surface_revision:, correspondent_id:, conversation_id:,
        bound_at:, bound_by:, status: 'active', version: 1, revocation_reason: nil
      )
        validate!(surface_id:, surface_revision:, correspondent_id:,
                  conversation_id:, status:, bound_at:, bound_by:, version:,
                  revocation_reason:)
        @surface_id = surface_id
        @surface_revision = surface_revision
        @correspondent_id = correspondent_id
        @conversation_id = conversation_id
        @status = status
        @bound_at = bound_at.utc
        @bound_by = bound_by
        @version = version
        @revocation_reason = revocation_reason
        freeze
      end

      def active? = status == 'active'

      def revoked? = status == 'revoked'

      def wire
        {
          'surface_id' => @surface_id,
          'surface_revision' => @surface_revision,
          'correspondent_id' => @correspondent_id,
          'conversation_id' => @conversation_id,
          'status' => @status,
          'bound_at' => @bound_at.iso8601(6),
          'bound_by' => @bound_by,
          'version' => @version,
          'revocation_reason' => @revocation_reason
        }
      end

      def self.from_wire(wire)
        new(
          surface_id: wire.fetch('surface_id'),
          surface_revision: wire.fetch('surface_revision'),
          correspondent_id: wire.fetch('correspondent_id'),
          conversation_id: wire.fetch('conversation_id'),
          status: wire.fetch('status'),
          bound_at: Time.parse(wire.fetch('bound_at')),
          bound_by: wire.fetch('bound_by'),
          version: wire.fetch('version'),
          revocation_reason: wire['revocation_reason']
        )
      end

      private

      def validate!(fields)
        Shapes.require_string!(fields.fetch(:surface_id), 'surface_id', max_bytes: MAX_ID_BYTES)
        Shapes.require_positive!(fields.fetch(:surface_revision), 'surface_revision')
        validate_parties!(fields.fetch(:correspondent_id), fields.fetch(:conversation_id))
        Shapes.require_member!(fields.fetch(:status), STATUSES, 'status')
        Shapes.require_time!(fields.fetch(:bound_at), 'bound_at')
        Shapes.require_string!(fields.fetch(:bound_by), 'bound_by', max_bytes: MAX_ID_BYTES)
        Shapes.require_positive!(fields.fetch(:version), 'version')
        return unless fields.fetch(:status) == 'revoked' && fields.fetch(:revocation_reason).nil?

        raise ValidationError, 'a revoked binding needs a revocation_reason'
      end

      def validate_parties!(correspondent_id, conversation_id)
        Shapes.require_prefixed!(correspondent_id, Parties.correspondent_prefixes,
                                 'correspondent_id must be a bound user id', max_bytes: MAX_ID_BYTES)
        Shapes.require_prefixed!(conversation_id, Parties.bindable_prefixes,
                                 'conversation_id must be a bound chat id', max_bytes: MAX_ID_BYTES)
        return if Parties.of_correspondent(correspondent_id) == Parties.of_conversation(conversation_id)

        raise ValidationError, 'a binding pairs a user and a chat of one surface kind'
      end
    end
  end
end

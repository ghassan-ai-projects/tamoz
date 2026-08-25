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
    # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    # :reek:LongParameterList, :reek:MissingSafeMethod, :reek:TooManyInstanceVariables
    # :reek:TooManyStatements, :reek:NilCheck
    class Binding
      STATUSES = %w[active revoked].freeze
      MAX_ID_BYTES = 256

      attr_reader :surface_id, :surface_revision, :correspondent_id,
                  :conversation_id, :status, :bound_at, :bound_by, :version,
                  :revocation_reason

      def initialize(
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

      def validate!(
        surface_id:, surface_revision:, correspondent_id:, conversation_id:,
        status:, bound_at:, bound_by:, version:, revocation_reason:
      )
        unless Shapes.bounded_string?(surface_id, max_bytes: MAX_ID_BYTES)
          raise ValidationError, 'surface_id must be a bounded string'
        end
        unless surface_revision.is_a?(Integer) && surface_revision.positive?
          raise ValidationError,
                'surface_revision must be a positive integer'
        end
        unless Shapes.bounded_string?(correspondent_id,
                                      max_bytes: MAX_ID_BYTES) && correspondent_id.start_with?('telegram:user:')
          raise ValidationError, 'correspondent_id must be a bound telegram user id'
        end
        unless Shapes.bounded_string?(conversation_id,
                                      max_bytes: MAX_ID_BYTES) && conversation_id.start_with?('telegram:chat:')
          raise ValidationError, 'conversation_id must be a bound telegram chat id'
        end
        raise ValidationError, "status must be one of #{STATUSES.join(', ')}" unless Shapes.member?(status, STATUSES)
        raise ValidationError, 'bound_at must be a Time value' unless bound_at.is_a?(Time)
        unless Shapes.bounded_string?(bound_by, max_bytes: MAX_ID_BYTES)
          raise ValidationError, 'bound_by must be a bounded string'
        end
        raise ValidationError, 'version must be a positive integer' unless version.is_a?(Integer) && version.positive?
        return unless status == 'revoked' && revocation_reason.nil?

        raise ValidationError, 'a revoked binding needs a revocation_reason'
      end
    end

    # One conversation route: conversation → thread, profile, threading mode
    # (design §13). The thread binding is write-once under the surface revision;
    # a different profile or revision rotates to a NEW thread generation instead
    # of rewriting an existing binding.
    # :reek:LongParameterList, :reek:MissingSafeMethod, :reek:TooManyInstanceVariables
    # :reek:TooManyStatements
    class Conversation
      MAX_ID_BYTES = 256

      attr_reader :surface_id, :surface_revision, :conversation_id, :thread_id,
                  :profile_id, :threading, :bound_at, :version

      def initialize(
        surface_id:, surface_revision:, conversation_id:, thread_id:,
        profile_id:, bound_at:, threading: 'conversation', version: 1
      )
        validate!(surface_id:, surface_revision:, conversation_id:, thread_id:,
                  profile_id:, threading:, bound_at:, version:)
        @surface_id = surface_id
        @surface_revision = surface_revision
        @conversation_id = conversation_id
        @thread_id = thread_id
        @profile_id = profile_id
        @threading = threading
        @bound_at = bound_at.utc
        @version = version
        freeze
      end

      def wire
        {
          'surface_id' => @surface_id,
          'surface_revision' => @surface_revision,
          'conversation_id' => @conversation_id,
          'thread_id' => @thread_id,
          'profile_id' => @profile_id,
          'threading' => @threading,
          'bound_at' => @bound_at.iso8601(6),
          'version' => @version
        }
      end

      def self.from_wire(wire)
        new(
          surface_id: wire.fetch('surface_id'),
          surface_revision: wire.fetch('surface_revision'),
          conversation_id: wire.fetch('conversation_id'),
          thread_id: wire.fetch('thread_id'),
          profile_id: wire.fetch('profile_id'),
          threading: wire.fetch('threading'),
          bound_at: Time.parse(wire.fetch('bound_at')),
          version: wire.fetch('version')
        )
      end

      private

      def validate!(
        surface_id:, surface_revision:, conversation_id:, thread_id:,
        profile_id:, threading:, bound_at:, version:
      )
        unless Shapes.bounded_string?(surface_id, max_bytes: MAX_ID_BYTES)
          raise ValidationError, 'surface_id must be a bounded string'
        end
        unless surface_revision.is_a?(Integer) && surface_revision.positive?
          raise ValidationError,
                'surface_revision must be a positive integer'
        end
        unless Shapes.bounded_string?(conversation_id,
                                      max_bytes: MAX_ID_BYTES) && conversation_id.start_with?('telegram:chat:')
          raise ValidationError, 'conversation_id must be a bound telegram chat id'
        end
        unless Shapes.bounded_string?(thread_id, max_bytes: MAX_ID_BYTES)
          raise ValidationError, 'thread_id must be a bounded string'
        end
        unless Shapes.bounded_string?(profile_id, max_bytes: MAX_ID_BYTES)
          raise ValidationError, 'profile_id must be a bounded string'
        end
        unless SurfaceDescriptor::THREADING_MODES.include?(threading)
          raise ValidationError, "threading must be one of #{SurfaceDescriptor::THREADING_MODES.join(', ')}"
        end
        raise ValidationError, 'bound_at must be a Time value' unless bound_at.is_a?(Time)
        raise ValidationError, 'version must be a positive integer' unless version.is_a?(Integer) && version.positive?
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength

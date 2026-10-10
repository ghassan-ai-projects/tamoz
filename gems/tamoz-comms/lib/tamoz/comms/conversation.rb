# frozen_string_literal: true

require 'time'

require_relative 'errors'
require_relative 'shapes'
require_relative 'surface_descriptor'

module Tamoz
  module Comms
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

      def initialize( # rubocop:disable Metrics/ParameterLists
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

      def validate!(fields)
        Shapes.require_string!(fields.fetch(:surface_id), 'surface_id', max_bytes: MAX_ID_BYTES)
        Shapes.require_positive!(fields.fetch(:surface_revision), 'surface_revision')
        raise ValidationError, 'conversation_id must be a bound chat id' unless
          Parties.bindable?(fields.fetch(:conversation_id))

        Shapes.require_string!(fields.fetch(:thread_id), 'thread_id', max_bytes: MAX_ID_BYTES)
        Shapes.require_string!(fields.fetch(:profile_id), 'profile_id', max_bytes: MAX_ID_BYTES)
        Shapes.require_member!(fields.fetch(:threading), SurfaceDescriptor::THREADING_MODES, 'threading')
        Shapes.require_time!(fields.fetch(:bound_at), 'bound_at')
        Shapes.require_positive!(fields.fetch(:version), 'version')
      end
    end
  end
end

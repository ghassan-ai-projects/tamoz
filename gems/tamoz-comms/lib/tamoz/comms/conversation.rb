# frozen_string_literal: true

require 'time'

require_relative 'errors'
require_relative 'shapes'
require_relative 'surface_descriptor'

module Tamoz
  module Comms
    Conversation = Data.define(:surface_id, :surface_revision, :conversation_id, :thread_id,
                               :profile_id, :threading, :bound_at, :version)

    # One conversation route: conversation → thread, profile, threading mode
    # (design §13). The thread binding is write-once under the surface revision;
    # a different profile or revision rotates to a NEW thread generation instead
    # of rewriting an existing binding.
    # :reek:MissingSafeMethod
    class Conversation
      MAX_ID_BYTES = 256
      DEFAULTS = { threading: 'conversation', version: 1 }.freeze

      def initialize(bound_at:, **fields)
        super(**DEFAULTS, **fields, bound_at: Shapes.utc(bound_at))
        validate!
      end

      def wire = to_h.transform_keys(&:to_s).merge('bound_at' => bound_at.iso8601(6))

      def self.from_wire(wire)
        new(**members.to_h { |name| [name, wire[name.to_s]] }, bound_at: Time.parse(wire.fetch('bound_at')))
      end

      private

      def validate!
        Shapes.require_string!(surface_id, 'surface_id', max_bytes: MAX_ID_BYTES)
        Shapes.require_positive!(surface_revision, 'surface_revision')
        raise ValidationError, 'conversation_id must be a bound chat id' unless Parties.bindable?(conversation_id)

        Shapes.require_string!(thread_id, 'thread_id', max_bytes: MAX_ID_BYTES)
        Shapes.require_string!(profile_id, 'profile_id', max_bytes: MAX_ID_BYTES)
        Shapes.require_member!(threading, SurfaceDescriptor::THREADING_MODES, 'threading')
        Shapes.require_time!(bound_at, 'bound_at')
        Shapes.require_positive!(version, 'version')
      end
    end
  end
end

# frozen_string_literal: true

require "tamoz/core"

module Tamoz
  module Stream
    # T1.5 (PLAN_TAMOZ_STREAM_BUILD T1.5): the RECEIVED situation snapshot —
    # consumed and digest-verified, never produced. (The old engine's
    # SituationSnapshot is the PRODUCED situation value; this module is the
    # wire-side verifier with the opposite role, so it carries its own name.)
    # The worker recomputes the snapshot digest with the shared rule
    # (CONTRACTS §3.2: domain situation-runtime/snapshot/v1) and compares it
    # in constant time; a tampered or drifted snapshot terminates the episode
    # BEFORE any model call. The strict scanner refuses malformed documents
    # (duplicate keys, unpaired surrogates, unsafe numbers) at the receive
    # boundary.
    module ReceivedSnapshot
      # The identity fields an episode needs to scope its memory (T0.3) and
      # its decisions, per the shared snapshot-v1 schema: the flat identity
      # plus the nested entity {type, id}. A snapshot without them cannot be
      # executed.
      REQUIRED_IDENTITY = %w[
        situation_id situation_version tenant_id situation_type
      ].freeze

      module_function

      # Returns the parsed snapshot Hash when the payload verifies; raises a
      # typed StreamError otherwise.
      def verify(snapshot_json, expected_digest)
        unless snapshot_json.is_a?(String) && !snapshot_json.empty?
          raise SnapshotIdentityError, "situation snapshot payload is empty"
        end

        value = Tamoz::Core.parse_json_strict(snapshot_json)
        unless Tamoz::Core.verify_digest(:snapshot, value, expected_digest)
          raise SnapshotDigestMismatchError,
                "received situation snapshot digest does not match its payload"
        end
        unless value.is_a?(Hash)
          raise SnapshotIdentityError, "situation snapshot must be a JSON object"
        end

        missing = REQUIRED_IDENTITY.reject do |key|
          if key == "situation_version"
            value[key].is_a?(Integer)
          else
            value[key].is_a?(String) && !value[key].empty?
          end
        end
        entity = value["entity"]
        unless entity.is_a?(Hash) &&
               entity["type"].is_a?(String) && !entity["type"].empty? &&
               entity["id"].is_a?(String) && !entity["id"].empty?
          missing << "entity.type/entity.id"
        end
        unless missing.empty?
          raise SnapshotIdentityError,
                "situation snapshot is missing identity fields: #{missing.join(", ")}"
        end

        value
      end
    end
  end
end

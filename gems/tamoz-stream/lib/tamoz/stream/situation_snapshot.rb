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
        require_payload!(snapshot_json)
        value = Tamoz::Core.parse_json_strict(snapshot_json)
        require_matching_digest!(value, expected_digest)
        require_object!(value)
        require_identity!(value)

        value
      end

      def require_payload!(snapshot_json)
        return if snapshot_json.is_a?(String) && !snapshot_json.empty?

        raise SnapshotIdentityError, "situation snapshot payload is empty"
      end

      def require_matching_digest!(value, expected_digest)
        return if Tamoz::Core.verify_digest(:snapshot, value, expected_digest)

        raise SnapshotDigestMismatchError,
              "received situation snapshot digest does not match its payload"
      end

      def require_object!(value)
        return if value.is_a?(Hash)

        raise SnapshotIdentityError, "situation snapshot must be a JSON object"
      end

      def require_identity!(value)
        missing = REQUIRED_IDENTITY.reject { |key| identity_present?(value, key) }
        missing << "entity.type/entity.id" unless entity_identity?(value["entity"])
        return if missing.empty?

        raise SnapshotIdentityError,
              "situation snapshot is missing identity fields: #{missing.join(", ")}"
      end

      def identity_present?(value, key)
        if key == "situation_version"
          value[key].is_a?(Integer)
        else
          value[key].is_a?(String) && !value[key].empty?
        end
      end

      def entity_identity?(entity)
        entity.is_a?(Hash) &&
          entity["type"].is_a?(String) && !entity["type"].empty? &&
          entity["id"].is_a?(String) && !entity["id"].empty?
      end
    end
  end
end

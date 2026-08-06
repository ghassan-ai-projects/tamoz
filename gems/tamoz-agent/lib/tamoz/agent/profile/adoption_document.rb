# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # The adoption registry's document as it comes off disk (§3.6). The bytes
      # are already parsed; this decides whether they may be believed, so the
      # registry asks one question instead of carrying the shape rules itself —
      # the same split `Tamoz::SQLite::CheckpointWire` makes for stored rows.
      #
      # Fail-closed, and this is the check standing between a tampered registry
      # and a profile being treated as adopted: a foreign schema_version is
      # refused rather than reinterpreted, and only a real sha256 digest counts
      # as an activation. Pinned by test/agent_profile_adoption_seams_test.rb.
      class AdoptionDocument
        SCHEMA_VERSION = 1

        def self.empty
          { 'schema_version' => SCHEMA_VERSION, 'activated' => {} }
        end

        def initialize(data)
          @data = data
        end

        def valid?
          @data.is_a?(Hash) && @data['schema_version'] == SCHEMA_VERSION &&
            activations.is_a?(Hash) && activations.all? { |id, digests| valid_activation?(id, digests) }
        end

        private

        def activations
          @data['activated']
        end

        # :reek:UtilityFunction — a pure shape predicate. Reek's remedy is to move
        # it to the class that owns the data; this IS that class, and giving it
        # instance state it does not need would be the worse trade.
        def valid_activation?(profile_id, digests)
          profile_id.is_a?(String) && digests.is_a?(Array) &&
            digests.all? { |digest| digest.is_a?(String) && DIGEST_PATTERN.match?(digest) }
        end
      end
    end
  end
end

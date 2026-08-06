# frozen_string_literal: true

# Tamoz::SQLite::CheckpointWire — the checkpoint store's wire-value validation
# layer (Q3 slice 1). Stored bytes are validated before they become values:
# enums are checked against the allowed vocabulary, statuses against the
# request lifecycle, and canonical values are load/re-dump/byte-compared.
# Corruption fails closed with CheckpointCorruptionError; invalid input with
# ConfigurationError. Pinned by the sqlite checkpoint/request-inbox tests.
module Tamoz
  module SQLite
    # Stateless validators over stored checkpoint/request bytes. Each method
    # exists to guard one wire contract; corruption or bad input never
    # silently passes.
    class CheckpointWire
      REQUEST_STATUSES = %w[queued claimed running redirecting completed failed].freeze

      def initialize(checkpoint_codec:)
        @checkpoint_codec = checkpoint_codec
      end

      def enum_text(value, allowed, name)
        text = value.to_s
        return text if allowed.include?(text)

        raise ConfigurationError, "#{name} is invalid"
      end

      # :reek:FeatureEnvy -- validating these params IS this class's purpose;
      # the rules cannot move to the value or the allowed list.
      def persisted_enum_symbol(value, allowed, name)
        return value.to_sym if value.is_a?(String) && allowed.include?(value)

        raise CheckpointCorruptionError, "stored #{name} is invalid"
      end

      def request_status(value)
        raise CheckpointCorruptionError, 'request status is invalid' unless REQUEST_STATUSES.include?(value)

        value.to_sym
      end

      def canonical_state_value(bytes, name)
        codec = @checkpoint_codec.state_codec
        value = codec.load(bytes)
        # Byte comparison: stored BLOBs decode as ASCII-8BIT (see
        # EffectJournal#decode_receipt).
        raise CheckpointCorruptionError, "#{name} is not canonical" unless codec.dump(value).b == bytes.b

        value
      end
    end
  end
end

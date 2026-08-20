# frozen_string_literal: true

module Tamoz
  module SQLite
    class Store
      PROTOCOL_VERSION = 1
      MAX_NAME_BYTES = 1_024
      MAX_LIMIT = 100_000
      PROTECTED_FORMAT = "tamoz.protected".freeze

      attr_reader :adapter, :state_codec, :protection

      def initialize(adapter:, state_codec: StateCodec.new, protection: nil)
        unless state_codec.is_a?(StateCodec)
          raise ConfigurationError, "Store state_codec must be a Tamoz::StateCodec"
        end
        validate_protection!(protection) if protection

        @adapter = adapter
        @state_codec = state_codec
        @protection = protection
        freeze
      end

      def protocol_version = PROTOCOL_VERSION
      def storage_identity = adapter
      def searchable? = false

      def search(*)
        raise StoreCapabilityError, "SQLite Store does not provide semantic search"
      end

      def put(namespace, key, value, if_version: nil, sensitive: false)
        address = normalize_address(namespace, key)
        expected = normalize_expected_version(if_version)
        unless sensitive == true || sensitive == false
          raise ConfigurationError, "sensitive must be true or false"
        end

        bytes = state_codec.dump(value)
        stored = sensitive ? protect(bytes, address:) : bytes
        append_version(address:, expected:, bytes: stored, sensitive:, deleted: false)
      end

      def get(namespace, key)
        address = normalize_address(namespace, key)
        row = adapter.__send__(:read, operation: "store.get") do |tx|
          current_row(tx, address, "store.get")
        end
        return nil unless row

        materialize(address, row)
      end

      # P11 (DC-3 atomic storage seam) — INTERNAL, not part of the stable public
      # API. `Tamoz::SQLite::MemoryStore` opens ONE transaction and appends
      # the Store version/head AND the memory index row inside it, so a kill
      # between the two writes leaves neither (no best-effort two-write).
      # Public `put`/`delete` delegate to the same primitive.
      def open_transaction(label:, &block)
        adapter.__send__(:transaction, operation: label, &block)
      end

      # P11 (DC-3) — INTERNAL. The shared append primitive: appends one Store
      # version row + head upsert inside the caller's already-open transaction.
      # Returns [Tamoz::StoreEntry, now_ms].
      def append_in_transaction(tx, namespace:, key:, expected:, bytes:, sensitive:, deleted:)
        address = normalize_address(namespace, key)
        expected_version = normalize_expected_version(expected)
        append_version_in_tx(tx, address:, expected: expected_version, bytes:, sensitive:, deleted:)
      end

      # P11 (DC-3) — INTERNAL. The Store's protection codec, used by
      # MemoryStore to protect a sensitive record before the one-transaction
      # append. No transaction is needed: the codec is pure.
      def protect_bytes(bytes, namespace:, key:)
        protect(bytes, address: normalize_address(namespace, key))
      end

      # P11 (DC-3) — INTERNAL. Reads one specific historical version of a Store
      # key (materialized + decrypted like `get`). MemoryStore uses this so
      # a corrected record's prior versions remain readable (probe P11-16:
      # "a historical read of R still works").
      def read_version(namespace, key, version)
        address = normalize_address(namespace, key)
        expected_version = normalize_expected_version(version)
        row = adapter.__send__(:read, operation: "store.read_version") do |tx|
          tx.first(
            "store.read_version",
            <<~SQL,
              SELECT v.version, v.deleted, v.sensitive,
                     v.payload, v.payload_digest, v.created_at_ms
              FROM tamoz_store_versions v
              WHERE v.namespace = ? AND v.key = ? AND v.version = ?
            SQL
            [address.fetch(0), address.fetch(1), expected_version]
          )
        end
        return nil unless row

        materialize(address, row)
      end

      # P11 (DC-3) — INTERNAL. The current Store head version for a key, or nil.
      # MemoryStore uses it to version historical reads and purge scans.
      def head_version(namespace, key)
        address = normalize_address(namespace, key)
        adapter.__send__(:read, operation: "store.head_version") do |tx|
          tx.scalar(
            "store.head_version",
            <<~SQL,
              SELECT current_version
              FROM tamoz_store_heads
              WHERE namespace = ? AND key = ?
            SQL
            address
          )
        end
      end

      def delete(namespace, key, if_version: nil)
        address = normalize_address(namespace, key)
        expected = normalize_expected_version(if_version)
        append_version(
          address:,
          expected:,
          bytes: nil,
          sensitive: false,
          deleted: true
        )
      end

      def each(namespace, prefix: nil, limit:)
        return enum_for(__method__, namespace, prefix:, limit:) unless block_given?

        namespace_text = normalize_name(namespace, "Store namespace")
        prefix_text = prefix.nil? ? nil : normalize_name(prefix, "Store prefix", allow_empty: true)
        normalized_limit = normalize_limit(limit)
        rows = adapter.__send__(:read, operation: "store.each") do |tx|
          predicate = prefix_text ? "AND h.key >= ? AND h.key < ?" : ""
          binds = [namespace_text]
          if prefix_text
            binds << prefix_text
            binds << prefix_upper_bound(prefix_text)
          end
          binds << normalized_limit
          tx.rows(
            "store.each",
            <<~SQL,
              SELECT h.key, v.version, v.deleted, v.sensitive,
                     v.payload, v.payload_digest, v.created_at_ms
              FROM tamoz_store_heads h
              JOIN tamoz_store_versions v
                ON v.namespace = h.namespace
               AND v.key = h.key
               AND v.version = h.current_version
              WHERE h.namespace = ? AND h.deleted = 0 #{predicate}
              ORDER BY h.key COLLATE BINARY
              LIMIT ?
            SQL
            binds
          )
        end
        rows.each do |row|
          address = [namespace_text, normalize_name(row.fetch(0), "stored Store key")]
          yield materialize(address, row)
        end
        self
      end

      private

      def append_version(address:, expected:, bytes:, sensitive:, deleted:)
        result = nil
        adapter.__send__(:transaction, operation: "store.compare_and_set") do |tx|
          result, = append_version_in_tx(
            tx, address:, expected:, bytes:, sensitive:, deleted:
          )
        end
        result
      rescue CheckpointCorruptionError => error
        raise StoreError.new("Store value could not be decoded"), cause: error
      end

      # The DC-3 shared append body: runs inside the CALLER's transaction. The
      # public `append_version` (put/delete) and MemoryStore both use it.
      def append_version_in_tx(tx, address:, expected:, bytes:, sensitive:, deleted:)
        now = adapter.__send__(:backend_time, tx, "store.cas.time")
        row = tx.first(
          "store.cas.head",
          <<~SQL,
            SELECT current_version, deleted, sensitive
            FROM tamoz_store_heads
            WHERE namespace = ? AND key = ?
          SQL
          address
        )
        current = row&.fetch(0)
        if expected.nil?
          raise StoreConflictError, "Store key already exists" if current
        elsif current != expected
          raise StoreConflictError, "Store version does not match"
        end
        if deleted && !current
          raise StoreConflictError, "Store key does not exist"
        end

        version = (current || 0) + 1
        digest = bytes && Wire.digest(bytes, domain: "tamoz.sqlite.store_value")
        tx.execute(
          "store.cas.version",
          <<~SQL,
            INSERT INTO tamoz_store_versions(
              namespace, key, version, deleted, sensitive,
              format_version, payload, payload_digest, created_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            *address, version, deleted ? 1 : 0, sensitive ? 1 : 0,
            PROTOCOL_VERSION, bytes && Wire.blob(bytes), digest, now
          ]
        )
        tx.execute(
          "store.cas.head_upsert",
          <<~SQL,
            INSERT INTO tamoz_store_heads(
              namespace, key, current_version, deleted, sensitive, updated_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(namespace, key) DO UPDATE SET
              current_version = excluded.current_version,
              deleted = excluded.deleted,
              sensitive = excluded.sensitive,
              updated_at_ms = excluded.updated_at_ms
            WHERE tamoz_store_heads.current_version = ?
          SQL
          [
            *address, version, deleted ? 1 : 0, sensitive ? 1 : 0, now,
            current || 0
          ]
        )
        if tx.changes != 1
          raise StoreConflictError, "Store head changed concurrently"
        end
        entry = Tamoz::StoreEntry.new(
          namespace: address.fetch(0),
          key: address.fetch(1),
          version:,
          value: deleted ? nil : state_codec.load(bytes_for_decode(bytes, sensitive, address)),
          sensitive:,
          deleted:,
          created_at_ms: now
        )
        [entry, now]
      end

      def current_row(tx, address, label)
        tx.first(
          label,
          <<~SQL,
            SELECT h.key, v.version, v.deleted, v.sensitive,
                   v.payload, v.payload_digest, v.created_at_ms
            FROM tamoz_store_heads h
            JOIN tamoz_store_versions v
              ON v.namespace = h.namespace
             AND v.key = h.key
             AND v.version = h.current_version
            WHERE h.namespace = ? AND h.key = ?
          SQL
          address
        )
      end

      def materialize(address, row)
        key_offset = row.length == 7 ? 1 : 0
        key = key_offset == 1 ? normalize_name(row.fetch(0), "stored Store key") : address.fetch(1)
        version = row.fetch(key_offset)
        deleted = row.fetch(key_offset + 1) == 1
        sensitive = row.fetch(key_offset + 2) == 1
        payload = row.fetch(key_offset + 3)
        digest = row.fetch(key_offset + 4)
        created_at = row.fetch(key_offset + 5)
        if deleted
          unless payload.nil? && digest.nil?
            raise CheckpointCorruptionError, "deleted Store version has payload"
          end
          value = nil
        else
          raise CheckpointCorruptionError, "Store payload is missing" unless payload && digest
          Wire.verify_digest!(payload, digest, domain: "tamoz.sqlite.store_value")
          clear = bytes_for_decode(payload, sensitive, [address.fetch(0), key])
          value = state_codec.load(clear)
          # Byte comparison: stored BLOBs decode as ASCII-8BIT (see
          # EffectJournal#decode_receipt).
          unless state_codec.dump(value).b == clear.b
            raise CheckpointCorruptionError, "Store value is not canonical"
          end
        end
        Tamoz::StoreEntry.new(
          namespace: address.fetch(0),
          key:,
          version:,
          value:,
          sensitive:,
          deleted:,
          created_at_ms: created_at
        )
      end

      def protect(bytes, address:)
        unless protection
          raise SensitiveValueError,
                "sensitive Store values require a named protection codec"
        end
        ciphertext = protection.encrypt(bytes, context: protection_context(address))
        unless ciphertext.is_a?(String)
          raise SensitiveValueError, "protection codec returned an invalid ciphertext"
        end
        JSON.generate([
          PROTECTED_FORMAT,
          1,
          protection.name,
          ciphertext.b.unpack1("H*")
        ])
      rescue SensitiveValueError
        raise
      rescue StandardError => error
        raise SensitiveValueError.new("Store value protection failed"), cause: error
      end

      def bytes_for_decode(bytes, sensitive, address)
        return bytes unless sensitive
        unless protection
          raise SensitiveValueError,
                "sensitive Store value requires its protection codec"
        end
        envelope = JSON.parse(bytes, create_additions: false, max_nesting: 8)
        unless envelope.is_a?(Array) && envelope.length == 4 &&
               envelope.fetch(0) == PROTECTED_FORMAT && envelope.fetch(1) == 1 &&
               envelope.fetch(2) == protection.name
          raise CheckpointCorruptionError, "protected Store envelope is invalid"
        end
        protection.decrypt(
          decode_hex(envelope.fetch(3)),
          context: protection_context(address)
        )
      rescue JSON::ParserError, ArgumentError => error
        raise CheckpointCorruptionError.new("protected Store envelope is invalid"), cause: error
      end

      def decode_hex(value)
        unless value.is_a?(String) &&
               value.bytesize.even? &&
               /\A[0-9a-f]*\z/.match?(value)
          raise CheckpointCorruptionError, "protected Store ciphertext is invalid"
        end

        [value].pack("H*")
      end

      def protection_context(address)
        "tamoz.store\0#{address.fetch(0)}\0#{address.fetch(1)}".b.freeze
      end

      def validate_protection!(value)
        unless value.respond_to?(:name) &&
               value.respond_to?(:encrypt) &&
               value.respond_to?(:decrypt)
          raise ConfigurationError,
                "Store protection must provide name, encrypt, and decrypt"
        end
        normalize_name(value.name, "Store protection name")
      end

      def normalize_address(namespace, key)
        [
          normalize_name(namespace, "Store namespace"),
          normalize_name(key, "Store key")
        ].freeze
      end

      def normalize_name(value, name, allow_empty: false)
        text = SafeText.normalize(
          value,
          name:,
          max_bytes: MAX_NAME_BYTES,
          error_class: ConfigurationError
        )
        raise ConfigurationError, "#{name} must not be empty" if !allow_empty && text.empty?

        text
      end

      def normalize_expected_version(value)
        return nil if value.nil?
        return value if value.is_a?(Integer) && value.positive?

        raise ConfigurationError, "if_version must be a positive integer or nil"
      end

      def normalize_limit(value)
        return value if value.is_a?(Integer) && value.between?(1, MAX_LIMIT)

        raise ConfigurationError, "Store limit must be between 1 and #{MAX_LIMIT}"
      end

      def prefix_upper_bound(prefix)
        "#{prefix}\u{10FFFF}"
      end

      private_constant :PROTOCOL_VERSION, :MAX_NAME_BYTES, :MAX_LIMIT,
                       :PROTECTED_FORMAT
    end
  end
end

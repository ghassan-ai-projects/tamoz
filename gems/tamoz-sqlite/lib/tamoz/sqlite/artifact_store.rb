# frozen_string_literal: true

require "digest"
require "tamoz/core"
require "tamoz/error"
require "tamoz/stream"

module Tamoz
  module SQLite
    # P3 (provenance/replay): the DURABLE verified artifact store — the
    # production backend behind the ArtifactStore interface. Tenant-scoped;
    # every (digest, bytes) pair is REHASHED on admission, so a tampered byte
    # fails retention and a tampered retained row fails resolution. The
    # in-memory ArtifactStore stays test-only.
    class ArtifactStore
      class ArtifactStoreError < Tamoz::Stream::StreamError
        CATEGORY = "stream_artifact_store"
      end

      def initialize(adapter:, tenant:)
        @adapter = adapter
        @tenant = String(tenant)
        raise ConfigurationError, "artifact store requires a tenant" if @tenant.empty?
      end

      def retain(digest:, bytes:, media_type: "application/json")
        normalized = Tamoz::Core.normalize_digest(String(digest))
        unless Tamoz::Core.valid_digest?(normalized)
          raise ArtifactStoreError, "artifact retention requires a sha256: hex digest"
        end
        unless bytes.is_a?(String) && !bytes.empty?
          raise ArtifactStoreError, "artifact retention requires a String document"
        end
        # The STRICT bytes column is TEXT: wire documents arrive as binary
        # (ASCII-8BIT) strings — tag them UTF-8 without altering the bytes, so
        # the admission rehash stays byte-exact.
        bytes = bytes.dup.force_encoding(Encoding::UTF_8)
        # Rehash on admission: the store verifies the bytes match the digest —
        # a corrupted or lying caller is refused, never stored.
        unless normalized == "sha256:#{Digest::SHA256.hexdigest(bytes)}"
          raise ArtifactStoreError,
                "artifact digest mismatch on admission: #{normalized}"
        end

        @adapter.__send__(:transaction, operation: "artifact.retain") do |tx|
          tx.execute(
            "artifact.retain.upsert",
            "INSERT INTO tamoz_artifacts (tenant_id, digest, media_type, bytes, retained_at)
             VALUES (?, ?, ?, ?, ?)
             ON CONFLICT (tenant_id, digest) DO UPDATE SET
               media_type = excluded.media_type, bytes = excluded.bytes,
               retained_at = excluded.retained_at",
            [@tenant, normalized, media_type, bytes, Time.now.to_i]
          )
        end
        resolve(normalized)
      end

      def resolve(digest)
        normalized = Tamoz::Core.normalize_digest(String(digest))
        @adapter.__send__(:read, operation: "artifact.resolve") do |tx|
          row = tx.first(
            "artifact.resolve.fetch",
            "SELECT digest, media_type, bytes, retained_at
             FROM tamoz_artifacts WHERE tenant_id = ? AND digest = ?",
            [@tenant, normalized]
          )
          next nil if row.nil?

          stored_digest, media_type, bytes, retained_at = row
          # Rehash on resolve: a tampered retained row fails verification.
          unless stored_digest == "sha256:#{Digest::SHA256.hexdigest(bytes)}"
            raise ArtifactStoreError,
                  "artifact digest mismatch on resolve: #{stored_digest}"
          end

          {
            "digest" => stored_digest,
            "bytes" => bytes,
            "media_type" => media_type,
            "retained_at" => retained_at
          }.freeze
        end
      end

      def size
        @adapter.__send__(:read, operation: "artifact.size") do |tx|
          tx.scalar(
            "artifact.size.count",
            "SELECT COUNT(*) FROM tamoz_artifacts WHERE tenant_id = ?", [@tenant]
          )
        end
      end
    end
  end
end

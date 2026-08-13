# frozen_string_literal: true

require "tamoz/stream/errors"
require "tamoz/core"

module Tamoz
  module Stream
    # T2.3 (PLAN_TAMOZ_STREAM_BUILD T2.3): the per-episode artifact store. The
    # terminal's artifact manifest names the digests a shadow run needs to
    # reproduce the accepted Decision without re-running Tamoz (PROTOCOL §2);
    # this store RETAINS the named documents so the manifest is resolvable.
    # Retention is keyed on the stream's OWN digests (the sha256: values the
    # wire carried), never on locally re-derived values, and is bounded —
    # entry count and total bytes — so a misbehaving peer cannot grow the
    # worker's memory unboundedly. Eviction policy is the deployment's; the
    # store is the mechanism, not the policy.
    class ArtifactStore
      MAX_ARTIFACTS = 1024
      MAX_TOTAL_BYTES = 64 * 1024 * 1024

      class ArtifactStoreError < StreamError
        CATEGORY = "stream_artifact_store"
      end

      # digest: the manifest's sha256: key; bytes: the retained document.
      def initialize(max_artifacts: MAX_ARTIFACTS, max_total_bytes: MAX_TOTAL_BYTES)
        @max_artifacts = max_artifacts
        @max_total_bytes = max_total_bytes
        @artifacts = {}
        @total_bytes = 0
      end

      attr_reader :total_bytes

      def retain(digest:, bytes:, media_type: "application/json")
        digest = String(Tamoz::Core.normalize_digest(digest))
        unless digest.match?(/\Asha256:[0-9a-f]{64}\z/)
          raise ArtifactStoreError, "artifact retention requires a sha256: hex digest"
        end
        unless bytes.is_a?(String)
          raise ArtifactStoreError, "artifact retention requires a String document"
        end
        # Idempotent per digest, but never keep-first on a collision: the same
        # digest with DIFFERENT bytes is a lying or corrupted peer, and
        # keeping the first silently poisons every later shadow comparison.
        if @artifacts.key?(digest)
          stored = @artifacts.fetch(digest)
          unless stored.fetch("bytes") == bytes
            raise ArtifactStoreError,
                  "artifact digest collision: #{digest} resolves to different bytes"
          end
          return stored
        end

        size = bytes.bytesize
        if size.zero?
          raise ArtifactStoreError, "artifact retention requires bytes"
        end
        if @artifacts.length >= @max_artifacts ||
           @total_bytes + size > @max_total_bytes
          raise ArtifactStoreError,
                "artifact retention bounds exceeded " \
                "(#{@artifacts.length} artifacts / #{@total_bytes} bytes)"
        end

        @artifacts[digest] = {
          "digest" => digest,
          "bytes" => bytes,
          "media_type" => media_type,
          "retained_at" => Time.now.to_i
        }.freeze
        @total_bytes += size
        @artifacts.fetch(digest)
      end

      def resolve(digest)
        @artifacts[String(Tamoz::Core.normalize_digest(digest))]
      end

      def size = @artifacts.length
    end
  end
end

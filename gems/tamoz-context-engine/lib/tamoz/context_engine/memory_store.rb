# frozen_string_literal: true

require 'digest'

module Tamoz
  module ContextEngine
    # An in-process content-addressed store with the ArtifactStore contract, for
    # the ephemeral runtime and tests.
    class MemoryStore
      def initialize
        @documents = {}
        @lock = Mutex.new
      end

      def retain(digest:, bytes:, media_type: 'text/plain')
        raise Error, 'digest mismatch on retain' unless digest == "sha256:#{Digest::SHA256.hexdigest(bytes)}"

        @lock.synchronize do
          @documents[digest] = { 'digest' => digest, 'bytes' => bytes.dup.freeze, 'media_type' => media_type }.freeze
        end
      end

      def resolve(digest) = @lock.synchronize { @documents[digest] }

      def size = @lock.synchronize { @documents.size }
    end
  end
end

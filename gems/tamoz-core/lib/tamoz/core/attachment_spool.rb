# frozen_string_literal: true

require 'digest'

module Tamoz
  module Core
    # A received file in transit from the gateway to the worker: written once, deleted once read, never kept.
    class AttachmentSpool
      MODE = 0o600
      NAME = /\A[0-9a-f]{64}\z/

      def initialize(directory)
        @directory = directory.to_s
      end

      # `name` is unique to the update that carried the file, so two requests never share one handoff.
      # @return [String] "sha256:<hex>" of the bytes, checked again when they are read.
      def put(name, bytes)
        PrivateDirectory.secure(@directory)
        AtomicFile.replace(path(name), bytes, mode: MODE)
        "sha256:#{Digest::SHA256.hexdigest(bytes)}"
      end

      # @return [String, nil] the bytes, or nil once they are gone.
      # @raise [ConfigurationError] the file no longer matches its digest.
      def read(name, digest:)
        bytes = File.binread(path(name))
        raise ConfigurationError, 'attachment bytes do not match their digest' unless
          digest == "sha256:#{Digest::SHA256.hexdigest(bytes)}"

        bytes
      rescue Errno::ENOENT
        nil
      end

      def delete(name)
        File.delete(path(name))
      rescue Errno::ENOENT
        nil
      end

      # Removes what no turn read in time: a refused or never-run request's file.
      def sweep(older_than:, now: Time.now)
        Dir.children(@directory).each do |name|
          file = File.join(@directory, name)
          File.delete(file) if File.file?(file) && now - File.mtime(file) > older_than
        end
      rescue Errno::ENOENT
        nil
      end

      private

      def path(name)
        raise ConfigurationError, 'attachment handoff name is malformed' unless NAME.match?(name.to_s)

        File.join(@directory, name)
      end
    end
  end
end

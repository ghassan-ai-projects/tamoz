# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Agent
    # P3 (provenance/replay): the sealed build fingerprint for benchmark runs.
    # The graph digest alone is not enough — node descriptors carry
    # caller-supplied version strings, not source (node_spec.rb). The
    # fingerprint binds the actual build: Ruby version, the lockfile digest,
    # argv, a sanitized env, and the loaded feature manifest.
    class SealedBuild
      ENV_ALLOWLIST = %w[
        LANG LC_ALL PATH RUBYOPT BUNDLE_GEMFILE
        TAMOZ_PROFILE TAMOZ_EPISODE_ENDPOINT
      ].freeze

      def self.fingerprint(lockfile_path: nil, argv: ARGV, env: ENV, loaded_features: $LOADED_FEATURES)
        new(lockfile_path:, argv:, env:, loaded_features:).fingerprint
      end

      def initialize(lockfile_path: nil, argv: ARGV, env: ENV, loaded_features: $LOADED_FEATURES)
        @lockfile_path = lockfile_path
        @argv = argv.to_a
        @env = env
        @loaded_features = loaded_features.to_a
      end

      # P7: the CANONICAL fingerprint for the benchmark protocol — fixed argv,
      # no loaded-features (which are machine-dependent), so the frozen
      # protocol regenerates byte-identically across processes and machines.
      def canonical_fingerprint
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical_document))}"
      end

      def fingerprint
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(document))}"
      end

      private

      def canonical_document
        {
          "ruby" => RUBY_VERSION,
          "ruby_patchlevel" => RUBY_PATCHLEVEL.to_s,
          "lockfile_sha256" => lockfile_digest
        }
      end

      def document
        {
          "ruby" => RUBY_VERSION,
          "ruby_patchlevel" => RUBY_PATCHLEVEL.to_s,
          "lockfile_sha256" => lockfile_digest,
          "argv" => @argv,
          "env" => sanitized_env,
          "features" => @loaded_features.sort
        }
      end

      def lockfile_digest
        path = @lockfile_path || default_lockfile
        return nil unless path && File.file?(path)

        "sha256:#{Digest::SHA256.hexdigest(File.binread(path))}"
      end

      # Ascends from the gem's lib directory to the repo root — the lockfile
      # is at the monorepo root, not inside the gem.
      def default_lockfile
        current = File.expand_path("..", __dir__)
        until File.dirname(current) == current
          candidate = File.join(current, "Gemfile.lock")
          return candidate if File.file?(candidate)

          current = File.dirname(current)
        end
        nil
      end

      def sanitized_env
        ENV_ALLOWLIST.to_h do |key|
          [key, @env[key]]
        end.reject { |_key, value| value.nil? }
      end
    end
  end
end

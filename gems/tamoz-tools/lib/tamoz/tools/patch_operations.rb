# frozen_string_literal: true

require 'digest'
require 'json'
require 'tempfile'

module Tamoz
  module Tools
    # Applies prepared patches through the atomic publication boundary.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:TooManyStatements
    # :reek:UncommunicativeVariableName :reek:UtilityFunction
    # rubocop:disable Metrics/AbcSize
    class PatchOperations
      def initialize(toolbox)
        @toolbox = toolbox
        @preparation = PatchPreparation.new(toolbox)
        freeze
      end

      def apply(arguments)
        patch = prepare(resolved_arguments(arguments))
        atomic_replace(patch.fetch(:path), patch.fetch(:after_content))
        after_digest = Digest::SHA256.hexdigest(patch.fetch(:after_content))
        return receipt(arguments, patch, after_digest) if arguments.key?('replacements')

        <<~TEXT.chomp
          Applied #{arguments.fetch('path')}
          before_sha256: #{patch.fetch(:before_digest)}
          after_sha256: #{after_digest}
        TEXT
      end

      def prepare(arguments)
        preparation.prepare(arguments)
      end

      def render_diff(path, patch)
        preparation.render_diff(path, patch)
      end

      def resolved_arguments(arguments)
        return arguments if arguments.key?('expected_sha256')

        state = Toolbox.observe(toolbox.root.join(arguments.fetch('path'))).fetch('state')
        arguments.merge('expected_sha256' => state)
      end

      private

      attr_reader :toolbox, :preparation

      def receipt(arguments, patch, after_digest)
        replacement_digest = Digest::SHA256.hexdigest(
          JSON.generate(patch.fetch(:replacements).map do |replacement|
            { 'byte_start' => replacement.fetch(:byte_start), 'byte_end' => replacement.fetch(:byte_end),
              'before' => replacement.fetch(:before_text), 'after' => replacement.fetch(:after_text) }
          end)
        )
        <<~TEXT.chomp
          Applied #{arguments.fetch('path')}
          replacements: #{patch.fetch(:replacements).length}
          replacement_digest: #{replacement_digest}
          before_sha256: #{patch.fetch(:before_digest)}
          after_sha256: #{after_digest}
        TEXT
      end

      def atomic_replace(path, content)
        mode = path.stat.mode & 0o777
        temporary = Tempfile.new(['.tamoz-', '.tmp'], path.dirname.to_s, binmode: true)
        begin
          temporary.write(content)
          temporary.flush
          temporary.fsync
          temporary.chmod(mode)
          temporary.fsync
          temporary.close
          File.rename(temporary.path, path.to_s)
          fsync_directory(path.dirname)
        ensure
          temporary.close! unless temporary.closed? && !File.exist?(temporary.path)
        end
      rescue SystemCallError => e
        raise ToolError, "atomic patch failed: #{e.class}"
      end

      def fsync_directory(directory)
        File.open(directory.to_s, File::RDONLY, &:fsync)
      rescue SystemCallError
        nil
      end
    end
    # rubocop:enable Metrics/AbcSize
  end
end

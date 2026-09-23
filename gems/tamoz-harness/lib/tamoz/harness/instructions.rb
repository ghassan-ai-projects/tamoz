# frozen_string_literal: true

require 'digest'
require 'pathname'

module Tamoz
  module Harness
    # Project guidance (AGENTS.md and the like) from the worked repository: untrusted, budgeted, body-only.
    module Instructions
      MAX_FILE_BYTES = 1024 * 1024

      # The wrapped guidance text and where it came from.
      Guidance = Data.define(:text, :digest, :sources, :truncated)

      module_function

      def load(root:, files:, max_bytes: 16_384)
        base = Pathname.new(root).realpath
        found = files.filter_map { |name| read(base, name) }
        return nil if found.empty?

        kept, truncated = fit(found, max_bytes)
        body = kept.map { |name, text| "## #{name}\n#{text.strip.gsub('</project-guidance>', '</project_guidance>')}" }
                   .join("\n\n")
        digest = "sha256:#{Digest::SHA256.hexdigest(body)}"
        Guidance.new(text: wrap(kept, body, digest, truncated), digest:, sources: kept.map(&:first), truncated:)
      end

      def read(base, name)
        if name.include?('/') || name.start_with?('.')
          raise Error,
                "guidance file must be a file name, got #{name.inspect}"
        end

        path = base.join(name)
        return if path.symlink? || !path.file? || path.size > MAX_FILE_BYTES

        text = path.read(encoding: 'BOM|UTF-8')
        [name, text] if text.valid_encoding? && !text.strip.empty?
      end

      # Broader files go first; when over budget the earliest are dropped, then the last one is cut.
      def fit(found, max_bytes)
        kept = found.dup
        kept.shift while kept.length > 1 && kept.sum { |_, text| text.bytesize } > max_bytes
        name, text = kept.last
        return [kept, found.length != kept.length] if text.bytesize <= max_bytes

        [kept[0...-1] + [[name, text.byteslice(0, max_bytes).scrub('')]], true]
      end

      def wrap(kept, body, digest, truncated)
        sources = kept.map(&:first).join(' ')
        "<project-guidance sources=\"#{sources}\" digest=\"#{digest}\" truncated=\"#{truncated}\">\n" \
          "#{PromptPack.fetch('project_guidance')}\n\n#{body}\n</project-guidance>"
      end
      private_class_method :read, :fit, :wrap
    end
  end
end

# frozen_string_literal: true

require 'digest'

module Tamoz
  module ContextEngine
    # Moves oversized tool output into the content-addressed store and leaves a
    # stub with enough to decide whether to recall it: locator, size, line count,
    # the producing tool's one-line digest, and a head/tail preview.
    class Spill
      LOCATOR_PATTERN = /\Aartifact:(sha256:[0-9a-f]{64})\z/
      # The model-visible text and, when spilled, the full output's digest.
      Result = Data.define(:text, :spilled)

      attr_reader :max_inline_bytes

      def initialize(store:, max_inline_bytes: 8192, head_lines: 20, tail_lines: 40)
        unless max_inline_bytes.is_a?(Integer) && max_inline_bytes >= 1024
          raise Error,
                'max_inline_bytes must be at least 1024'
        end

        @store = store
        @max_inline_bytes = max_inline_bytes
        @head_lines = head_lines
        @tail_lines = tail_lines
        freeze
      end

      def apply(output, summary:)
        return Result.new(text: output, spilled: nil) if output.bytesize <= @max_inline_bytes

        digest = "sha256:#{Digest::SHA256.hexdigest(output)}"
        @store.retain(digest:, bytes: output, media_type: 'text/plain')
        Result.new(text: stub(output, digest, summary), spilled: digest)
      end

      def self.recall(store, locator, offset: 1, limit: 200, pattern: nil)
        digest = LOCATOR_PATTERN.match(String(locator))&.[](1)
        raise Error, 'locator must be artifact:sha256:<64 hex>' unless digest

        document = store.resolve(digest)
        raise Error, "no spilled output at #{locator}" unless document

        lines = document.fetch('bytes').lines
        window = numbered(lines, pattern).select { |number, _| number >= offset }.first(limit)
        header = "artifact #{digest} · #{lines.length} lines · showing #{window.length}"
        ([header] + window.map { |number, line| "#{number}\t#{line.chomp}" }).join("\n")
      end

      def self.numbered(lines, pattern)
        numbered = lines.each_with_index.map { |line, index| [index + 1, line] }
        return numbered unless pattern

        expression = Regexp.new(pattern)
        numbered.select { |_, line| line.match?(expression) }
      rescue RegexpError => e
        raise Error, "invalid pattern: #{e.message}"
      end
      private_class_method :numbered

      private

      def stub(output, digest, summary)
        lines = output.lines
        head, tail = preview(lines)
        omitted = [lines.length - head.length - tail.length, 0].max
        [
          "[output spilled: artifact:#{digest} · #{facts(output, lines, summary).join(' · ')}]",
          head.join.chomp,
          "[... #{omitted} lines omitted · recall_output {\"locator\": \"artifact:#{digest}\"} ...]",
          tail.join.chomp
        ].join("\n")
      end

      def preview(lines)
        budget = (@max_inline_bytes - 512) / 3
        head = take_within(lines.first(@head_lines), budget)
        tail = take_within(lines.drop(head.length).last(@tail_lines).reverse, budget * 2).reverse
        [head, tail]
      end

      def facts(output, lines, summary)
        ["#{format('%.1f', output.bytesize / 1024.0)} KB", "#{lines.length} lines", digest_line(summary)].compact
      end

      def digest_line(summary)
        line = summary.to_s.lines.first.to_s.strip
        line.empty? ? nil : line.byteslice(0, 160).scrub
      end

      def take_within(lines, budget)
        taken = []
        used = 0
        lines.each do |line|
          line = "#{line.byteslice(0, 512).scrub}…\n" if line.bytesize > 512
          break if used + line.bytesize > budget

          taken << line
          used += line.bytesize
        end
        taken
      end
    end
  end
end

# frozen_string_literal: true

require 'digest'

module Tamoz
  module Tools
    # Validates patch evidence and computes byte-safe replacement plans.
    # :reek:DuplicateMethodCall :reek:LongParameterList :reek:NestedIterators
    # :reek:TooManyStatements :reek:UtilityFunction
    # rubocop:disable Layout/LineLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    class PatchPreparation
      def initialize(toolbox)
        @toolbox = toolbox
        freeze
      end

      def prepare(arguments)
        path = resolve(arguments.fetch('path'))
        raise ToolArgumentError, "file exceeds #{Toolbox::MAX_FILE_BYTES} bytes" if path.size > Toolbox::MAX_FILE_BYTES

        content = path.read(encoding: Encoding::UTF_8)
        raise ToolArgumentError, 'file is not valid UTF-8 text' unless content.valid_encoding?
        raise ToolArgumentError, 'file is not text' if content.include?("\0")

        expected = arguments.fetch('expected_sha256')
        actual = Digest::SHA256.hexdigest(content)
        unless actual == expected
          # D-8 committed intent: the digest the operator approved is a claim about
          # existing bytes, so a mismatch is a policy refusal (ToolPolicyError,
          # terminal), never a repairable argument value.
          raise ToolPolicyError, "file changed: expected digest #{expected}, observed #{actual}"
        end

        replacements = if arguments.key?('replacements')
                         build_compound(content, arguments.fetch('replacements'))
                       else
                         [build_single(content, arguments.fetch('before'), arguments.fetch('after'))]
                       end
        replacements.sort_by! { |entry| entry.fetch(:byte_start) }
        replacements.each_cons(2) do |left, right|
          raise ToolArgumentError, 'replacements overlap' if left.fetch(:byte_end) > right.fetch(:byte_start)
        end

        after_content = apply_replacements(content, replacements)
        if after_content.bytesize > Toolbox::MAX_FILE_BYTES
          raise ToolArgumentError, "patched file exceeds #{Toolbox::MAX_FILE_BYTES} bytes"
        end

        result = { path:, before_digest: actual, replacements: replacements.freeze, after_content: }
        unless arguments.key?('replacements')
          result.merge!(before_text: arguments.fetch('before'), after_text: arguments.fetch('after'),
                        line: replacements.first.fetch(:line))
        end
        result.freeze
      end

      def render_diff(display_path, patch)
        (patch[:replacements] || []).map do |replacement|
          before_lines = replacement.fetch(:before_text).lines(chomp: true)
          after_lines = replacement.fetch(:after_text).lines(chomp: true)
          line = replacement.fetch(:line)
          ["--- a/#{display_path}", "+++ b/#{display_path}", "@@ -#{line},#{before_lines.length} +#{line},#{after_lines.length} @@",
           *before_lines.map { |entry| "-#{entry}" }, *after_lines.map { |entry| "+#{entry}" }].join("\n")
        end.join("\n\n")
      end

      private

      attr_reader :toolbox

      def resolve(path)
        toolbox.__send__(:resolve, path, type: :file, allow_symlinks: false)
      end

      def build_compound(content, replacements)
        bytes = content.b
        replacements.group_by { |entry| entry.fetch('before') }.each_with_object([]) do |(before, group), canonical|
          before_bytes = before.b
          occurrences = bytes.scan(before_bytes).length
          raise ToolArgumentError, 'patch text was not found' if occurrences.zero?
          if occurrences < group.length
            raise ToolArgumentError, "patch text requested #{group.length} times but found #{occurrences} occurrences"
          end

          offset = 0
          group.each do |entry|
            byte_start = bytes.index(before_bytes, offset)
            canonical << replacement(byte_start, before_bytes.bytesize, before, entry.fetch('after'), content)
            offset = byte_start + before_bytes.bytesize
          end
        end
      end

      def build_single(content, before, after)
        bytes = content.b
        before_bytes = before.b
        occurrences = bytes.scan(before_bytes).length
        raise ToolArgumentError, 'patch text was not found' if occurrences.zero?
        raise ToolArgumentError, "patch text is ambiguous: found #{occurrences} occurrences" if occurrences > 1

        replacement(bytes.index(before_bytes), before_bytes.bytesize, before, after, content)
      end

      def replacement(byte_start, byte_length, before, after, content)
        { byte_start:, byte_end: byte_start + byte_length, before_text: before, after_text: after,
          line: content.byteslice(0, byte_start).count("\n") + 1 }.freeze
      end

      def apply_replacements(content, replacements)
        bytes = content.b
        result = +''.b
        cursor = 0
        replacements.each do |replacement|
          start = replacement.fetch(:byte_start)
          finish = replacement.fetch(:byte_end)
          result << bytes.byteslice(cursor, start - cursor) << replacement.fetch(:after_text).b
          cursor = finish
        end
        result << bytes.byteslice(cursor, bytes.bytesize - cursor)
        result.force_encoding(Encoding::UTF_8)
      end
    end
    # rubocop:enable Layout/LineLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end

# frozen_string_literal: true

module Tamoz
  module Skills
    # One SKILL.md, split into validated frontmatter fields and its body. Pure: `Disk` reads the text.
    class Manifest
      attr_reader :fields, :body

      def initialize(text, directory_name, limits)
        @label = directory_name
        frontmatter, @body = split(text, limits.fetch(:max_frontmatter_bytes))
        @fields = Frontmatter.new(frontmatter, directory_name, limits).call
        check_name!
        check_body!(frontmatter, limits.fetch(:max_body_bytes))
        freeze
      end

      private

      def split(text, limit)
        reject!('skill_frontmatter_missing', 'SKILL.md has no frontmatter') unless text.start_with?("---\n", "---\r\n")

        rest = text.sub(/\A---\r?\n/, '')
        terminator = FRONTMATTER_TERMINATOR.match(rest)
        reject!('skill_frontmatter_missing', 'frontmatter is unterminated') unless terminator

        frontmatter = rest[0, terminator.begin(0)]
        size = frontmatter.bytesize
        reject!('skill_frontmatter_bytes_exceeded', "frontmatter is #{size} bytes") if size > limit
        [frontmatter, rest[terminator.end(0)..].to_s]
      end

      # The spec: a skill's name is its directory's name.
      def check_name!
        name = fields.fetch('name')
        reject!('skill_name_mismatch', "frontmatter name #{Skills.describe(name)} != directory") unless name == @label
      end

      # A body holding the attribution sentinel could close its own fence and pass as framework text.
      def check_body!(frontmatter, limit)
        size = body.bytesize
        reject!('skill_body_bytes_exceeded', "body is #{size} bytes, limit #{limit}") if size > limit
        return unless body.include?(DELIMITER_SENTINEL) || frontmatter.include?(DELIMITER_SENTINEL)

        reject!('skill_delimiter_forgery', 'content contains the attribution delimiter')
      end

      def reject!(code, detail) = raise(Rejected.new(code, @label, detail))
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Skills
    # A skill directory as the walk found it: every entry's relative path, kind, digest and executable bit.
    Tree = Data.define(:entries) do
      def manifest? = entries.any? { |entry| entry.fetch(:path) == MANIFEST_BASENAME }

      # Relative paths only: the same tree at two locations has one identity, and no absolute path enters a digest.
      def digest
        rows = entries.map do |entry|
          [entry.fetch(:path), entry.fetch(:kind), entry[:digest], entry.fetch(:executable)]
        end
        Skills.digest_of(TREE_DIGEST_DOMAIN, JSON.generate(rows))
      end

      def resource_index
        files = entries.select { |entry| entry.fetch(:kind) == 'file' }
        files.to_h do |entry|
          [entry.fetch(:path), SkillResource.new(**entry.slice(:path, :area, :bytes, :digest, :executable))]
        end.freeze
      end
    end
  end
end

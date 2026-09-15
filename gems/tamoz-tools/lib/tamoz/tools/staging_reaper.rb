# frozen_string_literal: true

require 'find'
require 'pathname'

module Tamoz
  module Tools
    # Removes only stale, regular files left by interrupted atomic publication.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList
    # :reek:TooManyStatements :reek:UtilityFunction
    # rubocop:disable Layout/LineLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    class StagingReaper
      # Only the Tempfile-produced shape is provenance: date-pid-random, which no
      # operator file wears. A file merely starting `.tamoz-` (e.g. `.tamoz-notes.tmp`)
      # is the operator's and must survive.
      PATTERN = /\A\.tamoz-(?:create-)?\d{8}-\d+-[a-z0-9]+\.tmp\z/
      IGNORED_DIRECTORIES = %w[.git vendor node_modules].freeze
      MAX_FILES = 200
      DEFAULT_AGE = 60.0

      def initialize(root)
        @root = root
        freeze
      end

      def reap(older_than: DEFAULT_AGE, now: Time.now)
        removed = []
        stale_files(older_than:, now:).each do |path|
          break if removed.length >= MAX_FILES

          begin
            File.unlink(path.to_s)
            removed << path.relative_path_from(root).to_s
          rescue SystemCallError
            nil
          end
        end
        removed.freeze
      end

      def stale_files(older_than:, now:)
        found = []
        Find.find(root.to_s) do |entry|
          path = Pathname.new(entry)
          stat = File.lstat(entry)
          collect(path, stat, found, older_than:, now:)
          break if found.length >= MAX_FILES
        rescue SystemCallError
          next
        end
        found.sort_by(&:to_s)
      rescue SystemCallError
        []
      end

      private

      attr_reader :root

      def collect(path, stat, found, older_than:, now:)
        if stat.symlink?
          Find.prune if path.directory?
        elsif stat.directory?
          Find.prune if IGNORED_DIRECTORIES.include?(path.basename.to_s)
        elsif stat.file? && PATTERN.match?(path.basename.to_s) && stat.uid == Process.uid && now - stat.mtime >= older_than
          found << path
        end
      end
    end
    # rubocop:enable Layout/LineLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end

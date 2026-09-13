# frozen_string_literal: true

require 'find'
require 'digest'
require 'pathname'

module Tamoz
  module Tools
    # Implements bounded, read-only filesystem queries for Toolbox.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:TooManyStatements :reek:UtilityFunction
    class ReadOperations
      IGNORED_DIRECTORIES = %w[.git vendor node_modules].freeze

      def initialize(toolbox)
        @toolbox = toolbox
        freeze
      end

      def read_file(arguments)
        path = resolve(arguments.fetch('path'), type: :file)
        raise ToolArgumentError, "file exceeds #{Toolbox::MAX_FILE_BYTES} bytes" if path.size > Toolbox::MAX_FILE_BYTES

        content = path.read(encoding: Encoding::UTF_8)
        raise ToolArgumentError, 'file is not valid UTF-8 text' unless content.valid_encoding?
        raise ToolArgumentError, 'file is not text' if content.include?("\0")

        <<~TEXT.chomp
          File: #{arguments.fetch('path')}
          sha256: #{Digest::SHA256.hexdigest(content)}
          content:
          #{content}
        TEXT
      end

      def list_directory(arguments)
        path = resolve(arguments.fetch('path', '.'), type: :directory)
        children = path.children
        entries = children.min_by(Toolbox::MAX_DIRECTORY_ENTRIES) { |entry| entry.basename.to_s }
        rendered = entries.map { |entry| "#{entry.basename}#{'/' if entry.directory?}" }
        rendered << '... truncated' if children.length > Toolbox::MAX_DIRECTORY_ENTRIES
        rendered.join("\n")
      end

      def search_text(arguments)
        query = arguments.fetch('query')
        base = resolve(arguments.fetch('path', '.'), type: :any)
        candidates = base.file? ? [base] : searchable_files(base)
        results = []
        candidates.each do |path|
          break if results.length >= Toolbox::MAX_SEARCH_RESULTS

          results.concat(search_file(path, query, remaining: Toolbox::MAX_SEARCH_RESULTS - results.length))
        rescue SystemCallError, IOError
          nil
        end
        results.empty? ? 'No matches.' : results.join("\n")
      end

      private

      attr_reader :toolbox

      def resolve(raw_path, type:)
        toolbox.__send__(:resolve, raw_path, type:)
      end

      def searchable_files(base)
        files = []
        Find.find(base.to_s) do |entry|
          collect_search_path(Pathname.new(entry), files)
          break if files.length >= Toolbox::MAX_SEARCH_FILES
        end
        files.sort_by(&:to_s)
      end

      def collect_search_path(path, files)
        if path.symlink?
          Find.prune if path.directory?
        elsif path.directory?
          Find.prune if IGNORED_DIRECTORIES.include?(path.basename.to_s)
        elsif path.file?
          files << path
        end
      end

      def search_file(path, query, remaining:)
        return [] if path.size > Toolbox::MAX_FILE_BYTES

        content = path.read(encoding: Encoding::UTF_8)
        unless content.valid_encoding?
          relative = path.relative_path_from(toolbox.root)
          raise ToolArgumentError, "#{relative}: file is not valid UTF-8 text"
        end

        content.each_line.with_index(1).each_with_object([]) do |(line, number), matches|
          matches << "#{path.relative_path_from(toolbox.root)}:#{number}:#{line.chomp}" if line.include?(query)
          break matches if matches.length >= remaining
        end
      end
    end
  end
end

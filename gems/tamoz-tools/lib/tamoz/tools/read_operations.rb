# frozen_string_literal: true

require 'find'
require 'digest'
require 'pathname'

module Tamoz
  module Tools
    # Implements bounded, read-only filesystem queries for Toolbox.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:TooManyStatements :reek:UtilityFunction
    # :reek:LongParameterList :reek:TooManyConstants :reek:TooManyMethods -- one bounded read surface per toolbox.
    class ReadOperations
      IGNORED_DIRECTORIES = %w[.git vendor node_modules].freeze
      MAX_RANGED_FILE_BYTES = 4 * 1024 * 1024
      MAX_RANGE_LINES = 2_000
      MAX_GLOB_RESULTS = 500
      REGEX_TIMEOUT = 1.0
      GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

      def initialize(toolbox)
        @toolbox = toolbox
        freeze
      end

      def read_file(arguments)
        return read_range(arguments) if arguments.key?('offset') || arguments.key?('limit')

        path = resolve(arguments.fetch('path'), type: :file)
        raise ToolArgumentError, "file exceeds #{Toolbox::MAX_FILE_BYTES} bytes; read it by range" if
          path.size > Toolbox::MAX_FILE_BYTES

        content = text_of(path)

        <<~TEXT.chomp
          File: #{arguments.fetch('path')}
          sha256: #{Digest::SHA256.hexdigest(content)}
          content:
          #{content}
        TEXT
      end

      def read_range(arguments)
        path = resolve(arguments.fetch('path'), type: :file)
        raise ToolArgumentError, "file exceeds #{MAX_RANGED_FILE_BYTES} bytes" if path.size > MAX_RANGED_FILE_BYTES

        content = text_of(path)
        lines = content.lines
        first = within_file(arguments.fetch('offset', 1), lines.length)
        window = line_window(lines, first, arguments.fetch('limit', MAX_RANGE_LINES))
        shown = bounded(numbered(window, first))
        [*range_header(arguments.fetch('path'), content, first, shown.length), *shown,
         *truncation(shown, window, first)].join("\n")
      end

      # Matching is pure string work (File.fnmatch?) over a walk that never leaves the
      # workspace, so braces, escapes and symlinked directories cannot reach outside it.
      def glob(arguments)
        base = resolve(arguments.fetch('path', '.'), type: :directory)
        pattern = arguments.fetch('pattern')
        matches = searchable_files(base).filter_map do |path|
          relative = path.relative_path_from(base).to_s
          path.relative_path_from(toolbox.root).to_s if File.fnmatch?(pattern, relative, GLOB_FLAGS)
        end
        rendered = matches.first(MAX_GLOB_RESULTS)
        rendered << "... truncated (#{matches.length} matches)" if matches.length > MAX_GLOB_RESULTS
        rendered.empty? ? 'No files.' : rendered.join("\n")
      end

      def list_directory(arguments)
        path = resolve(arguments.fetch('path', '.'), type: :directory)
        entries = path.children.sort_by { |entry| entry.basename.to_s }.first(Toolbox::MAX_DIRECTORY_ENTRIES)
        rendered = entries.map { |entry| "#{entry.basename}#{'/' if entry.directory?}" }
        rendered << '... truncated' if path.children.length > Toolbox::MAX_DIRECTORY_ENTRIES
        rendered.join("\n")
      end

      def search_text(arguments)
        query = arguments.fetch('query')
        query = Regexp.new(query, timeout: REGEX_TIMEOUT) if arguments['regex']
        base = resolve(arguments.fetch('path', '.'), type: :any)
        candidates = base.file? ? [base] : searchable_files(base)
        results = []
        candidates.each do |path|
          break if results.length >= Toolbox::MAX_SEARCH_RESULTS

          results.concat(search_file(path, query, remaining: Toolbox::MAX_SEARCH_RESULTS - results.length))
        rescue Regexp::TimeoutError
          raise ToolArgumentError, 'regular expression is too slow; use a simpler pattern'
        rescue SystemCallError, IOError
          nil
        end
        results.empty? ? 'No matches.' : results.join("\n")
      end

      private

      attr_reader :toolbox

      def text_of(path)
        content = path.read(encoding: Encoding::UTF_8)
        raise ToolArgumentError, 'file is not valid UTF-8 text' unless content.valid_encoding?
        raise ToolArgumentError, 'file is not text' if content.include?("\0")

        content
      end

      def within_file(first, count)
        return first if first <= [count, 1].max

        raise ToolArgumentError, "offset #{first} is past the end of the file (#{count} lines)"
      end

      def range_header(path, content, first, count)
        range = "lines: #{first}-#{first + count - 1} of #{content.lines.length}"
        range += ' (CRLF line endings)' if content.include?("\r\n")
        ["File: #{path}", "sha256: #{Digest::SHA256.hexdigest(content)}", range]
      end

      def truncation(shown, window, first)
        shown.length < window.length ? ["... truncated; continue with offset #{first + shown.length}"] : []
      end

      def bounded(lines)
        used = 0
        lines.take_while { |line| (used += line.bytesize + 1) <= Toolbox::MAX_FILE_BYTES }
      end

      def numbered(lines, first) = lines.each_with_index.map { |line, index| "#{first + index}\t#{line.chomp}" }

      def line_window(lines, first, limit) = lines[first - 1, [limit, MAX_RANGE_LINES].min] || []

      def matches?(line, query) = query.is_a?(Regexp) ? line.match?(query) : line.include?(query)

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
          matches << "#{path.relative_path_from(toolbox.root)}:#{number}:#{line.chomp}" if matches?(line, query)
          break matches if matches.length >= remaining
        end
      end
    end
  end
end

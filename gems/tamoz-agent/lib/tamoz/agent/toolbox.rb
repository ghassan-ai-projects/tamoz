# frozen_string_literal: true

require "find"
require "pathname"

module Tamoz
  module Agent
    class Toolbox
      MAX_FILE_BYTES = 64 * 1024
      MAX_DIRECTORY_ENTRIES = 200
      MAX_SEARCH_FILES = 2_000
      MAX_SEARCH_RESULTS = 100

      DESCRIPTIONS = {
        "read_file" => "Read UTF-8 text. Arguments: {\"path\": \"relative/file\"}.",
        "list_directory" => "List entries. Arguments: {\"path\": \"relative/directory\"}; path is optional.",
        "search_text" => "Find literal text. Arguments: {\"query\": \"text\", \"path\": \"relative/path\"}; path is optional."
      }.freeze

      attr_reader :root

      def initialize(root:)
        @root = Pathname.new(root).expand_path.realpath.freeze
        raise ToolError, "workspace root is not a directory" unless @root.directory?
      rescue SystemCallError
        raise ToolError, "workspace root is unavailable"
      end

      def descriptions = DESCRIPTIONS
      def names = DESCRIPTIONS.keys

      def validate(name, arguments)
        normalized_name = String(name)
        unless names.include?(normalized_name)
          raise ToolError, "unknown tool #{normalized_name.inspect}"
        end
        raise ToolError, "tool arguments must be an object" unless arguments.is_a?(Hash)

        normalized_arguments = arguments.transform_keys(&:to_s)
        case normalized_name
        when "read_file"
          reject_unknown!(normalized_arguments, %w[path])
          validate_path_argument!(normalized_arguments.fetch("path"))
        when "list_directory"
          reject_unknown!(normalized_arguments, %w[path])
          validate_path_argument!(normalized_arguments.fetch("path", "."))
        when "search_text"
          reject_unknown!(normalized_arguments, %w[path query])
          validate_path_argument!(normalized_arguments.fetch("path", "."))
          query = normalized_arguments.fetch("query")
          raise ToolError, "query must be a string" unless query.is_a?(String)
          raise ToolError, "query must not be empty" if query.empty?
          raise ToolError, "query exceeds 256 bytes" if query.bytesize > 256
        end
        normalized_arguments.freeze
      rescue KeyError => error
        raise ToolError, "missing tool argument #{error.key.inspect}"
      end

      def execute(name, arguments)
        normalized_name = String(name)
        normalized_arguments = validate(normalized_name, arguments)

        case normalized_name
        when "read_file"
          read_file(normalized_arguments)
        when "list_directory"
          list_directory(normalized_arguments)
        when "search_text"
          search_text(normalized_arguments)
        else
          raise ToolError, "unknown tool #{normalized_name.inspect}"
        end
      end

      private

      def read_file(arguments)
        path = resolve(arguments.fetch("path"), type: :file)
        raise ToolError, "file exceeds #{MAX_FILE_BYTES} bytes" if path.size > MAX_FILE_BYTES

        content = path.read(encoding: Encoding::UTF_8)
        raise ToolError, "file is not text" if content.include?("\0")

        content
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        raise ToolError, "file is not valid UTF-8 text"
      end

      def list_directory(arguments)
        path = resolve(arguments.fetch("path", "."), type: :directory)
        entries = path.children.sort_by { |entry| entry.basename.to_s }.first(MAX_DIRECTORY_ENTRIES)
        rendered = entries.map do |entry|
          suffix = entry.directory? ? "/" : ""
          "#{entry.basename}#{suffix}"
        end
        rendered << "... truncated" if path.children.length > MAX_DIRECTORY_ENTRIES
        rendered.join("\n")
      end

      def search_text(arguments)
        query = arguments.fetch("query")

        base = resolve(arguments.fetch("path", "."), type: :any)
        candidates = base.file? ? [base] : searchable_files(base)
        results = []
        candidates.each do |path|
          break if results.length >= MAX_SEARCH_RESULTS
          next if path.size > MAX_FILE_BYTES

          path.each_line.with_index(1) do |line, number|
            next unless line.include?(query)

            relative = path.relative_path_from(root)
            results << "#{relative}:#{number}:#{line.chomp}"
            break if results.length >= MAX_SEARCH_RESULTS
          end
        rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
          next
        end
        results.empty? ? "No matches." : results.join("\n")
      end

      def searchable_files(base)
        files = []
        Find.find(base.to_s) do |entry|
          path = Pathname.new(entry)
          if path.symlink?
            Find.prune if path.directory?
          elsif path.directory? && %w[.git vendor node_modules].include?(path.basename.to_s)
            Find.prune
          elsif path.file?
            files << path
            break if files.length >= MAX_SEARCH_FILES
          end
        end
        files.sort_by(&:to_s)
      end

      def resolve(raw_path, type:)
        text = String(raw_path)
        raise ToolError, "path must be relative to the workspace root" if Pathname.new(text).absolute?

        path = root.join(text).realpath
        prefix = "#{root}#{File::SEPARATOR}"
        unless path == root || path.to_s.start_with?(prefix)
          raise ToolError, "path escapes the workspace root"
        end
        if type == :file && !path.file?
          raise ToolError, "path is not a file"
        elsif type == :directory && !path.directory?
          raise ToolError, "path is not a directory"
        end

        path
      rescue SystemCallError
        raise ToolError, "path is unavailable"
      end

      def validate_path_argument!(raw_path)
        raise ToolError, "path must be a string" unless raw_path.is_a?(String)

        text = raw_path
        raise ToolError, "path contains a null byte" if text.include?("\0")
        raise ToolError, "path must be relative to the workspace root" if Pathname.new(text).absolute?
      end

      def reject_unknown!(arguments, allowed)
        unknown = arguments.keys - allowed
        raise ToolError, "unknown tool arguments: #{unknown.sort.join(", ")}" unless unknown.empty?
      end
    end
  end
end

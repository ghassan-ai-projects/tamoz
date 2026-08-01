# frozen_string_literal: true

require "find"
require "digest"
require "json"
require "open3"
require "pathname"
require "tempfile"
require "timeout"

module Tamoz
  module Agent
    CheckReceipt = Data.define(:name, :outcome, :stdout, :stderr) do
      def initialize(name:, outcome:, stdout:, stderr:)
        super(
          name: String(name).dup.freeze,
          outcome: String(outcome).dup.freeze,
          stdout: String(stdout).dup.freeze,
          stderr: String(stderr).dup.freeze
        )
      end

      def passed? = outcome == "exit_0"
      def failed? = !passed?

      def failure_signature
        return nil if passed?

        Digest::SHA256.hexdigest(
          JSON.generate(
            "name" => name,
            "outcome" => outcome,
            "stdout" => normalized_output(stdout),
            "stderr" => normalized_output(stderr)
          )
        )
      end

      def to_s
        <<~TEXT.chomp
          Check #{name}: #{outcome}
          stdout:
          #{stdout}
          stderr:
          #{stderr}
        TEXT
      end

      private

      def normalized_output(value)
        value
          .gsub(/\e\[[0-?]*[ -\/]?[@-~]/, "")
          .gsub("\r\n", "\n")
          .lines
          .map(&:rstrip)
          .join("\n")
          .strip
      end
    end

    class Toolbox
      MAX_FILE_BYTES = 64 * 1024
      MAX_DIRECTORY_ENTRIES = 200
      MAX_SEARCH_FILES = 2_000
      MAX_SEARCH_RESULTS = 100
      MAX_PATCH_BYTES = 64 * 1024
      MAX_CHECK_OUTPUT_BYTES = 64 * 1024
      DEFAULT_CHECK_TIMEOUT = 60.0

      READ_DESCRIPTIONS = {
        "read_file" => "Read UTF-8 text with its SHA-256 digest. Arguments: {\"path\": \"relative/file\"}.",
        "list_directory" => "List entries. Arguments: {\"path\": \"relative/directory\"}; path is optional.",
        "search_text" => "Find literal text. Arguments: {\"query\": \"text\", \"path\": \"relative/path\"}; path is optional."
      }.freeze
      ACTION_DESCRIPTIONS = {
        "apply_patch" => "Replace one exact text occurrence atomically. expected_sha256 must come from current read_file evidence. Arguments: {\"path\": \"relative/file\", \"expected_sha256\": \"64 hex characters\", \"before\": \"exact existing text\", \"after\": \"replacement text\"}.",
        "run_check" => "Run one user-configured command by name without a shell. Arguments: {\"name\": \"configured check name\"}."
      }.freeze

      attr_reader :root, :checks, :check_timeout

      def initialize(root:, allow_changes: false, checks: {}, check_timeout: DEFAULT_CHECK_TIMEOUT)
        @root = Pathname.new(root).expand_path.realpath.freeze
        raise ToolError, "workspace root is not a directory" unless @root.directory?
        unless allow_changes == true || allow_changes == false
          raise ArgumentError, "allow_changes must be true or false"
        end
        unless check_timeout.is_a?(Numeric) && check_timeout.positive? && check_timeout <= 600
          raise ArgumentError, "check_timeout must be between 0 and 600 seconds"
        end

        @allow_changes = allow_changes
        @checks = normalize_checks(checks)
        @check_timeout = check_timeout.to_f
        @descriptions = READ_DESCRIPTIONS.dup
        if @allow_changes
          @descriptions["apply_patch"] = ACTION_DESCRIPTIONS.fetch("apply_patch")
          unless @checks.empty?
            names = @checks.keys.sort.join(", ")
            @descriptions["run_check"] = "#{ACTION_DESCRIPTIONS.fetch("run_check")} Configured names: #{names}."
          end
        end
        @descriptions.freeze
      rescue SystemCallError
        raise ToolError, "workspace root is unavailable"
      end

      def descriptions = @descriptions
      def names = descriptions.keys
      def read_only_names = READ_DESCRIPTIONS.keys
      def action_capable? = @allow_changes
      def approval_required?(name) = %w[apply_patch run_check].include?(String(name))

      def maximum_effect_output_bytes(name)
        case String(name)
        when "apply_patch" then 6 * 1024
        when "run_check" then MAX_CHECK_OUTPUT_BYTES + 1024
        else 0
        end
      end

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
          raise ToolError, "query must not contain a null byte" if query.include?("\0")
          raise ToolError, "query must be UTF-8 encoded" unless query.encoding == Encoding::UTF_8
          raise ToolError, "query must be valid UTF-8" unless query.valid_encoding?
        when "apply_patch"
          reject_unknown!(normalized_arguments, %w[after before expected_sha256 path])
          validate_path_argument!(normalized_arguments.fetch("path"))
          validate_patch_text!(normalized_arguments.fetch("before"), name: "before", empty: false)
          validate_patch_text!(normalized_arguments.fetch("after"), name: "after", empty: true)
          digest = normalized_arguments.fetch("expected_sha256")
          unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
            raise ToolError, "expected_sha256 must be 64 lowercase hex characters"
          end
        when "run_check"
          reject_unknown!(normalized_arguments, %w[name])
          check_name = normalized_arguments.fetch("name")
          raise ToolError, "check name must be a string" unless check_name.is_a?(String)
          raise ToolError, "unknown configured check #{check_name.inspect}" unless checks.key?(check_name)
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
        when "apply_patch"
          apply_patch(normalized_arguments)
        when "run_check"
          run_check(normalized_arguments)
        else
          raise ToolError, "unknown tool #{normalized_name.inspect}"
        end
      end

      def preview(name, arguments)
        normalized_name = String(name)
        normalized_arguments = validate(normalized_name, arguments)

        case normalized_name
        when "apply_patch"
          patch = prepare_patch(normalized_arguments)
          render_diff(normalized_arguments.fetch("path"), patch)
        when "run_check"
          argv = checks.fetch(normalized_arguments.fetch("name"))
          "$ #{argv.map { |entry| shell_display(entry) }.join(" ")}"
        else
          raise ToolError, "tool #{normalized_name.inspect} does not require approval"
        end
      end

      private

      def normalize_checks(value)
        raise ArgumentError, "checks must be a Hash" unless value.is_a?(Hash)

        value.to_h do |raw_name, raw_argv|
          name = String(raw_name)
          unless name.match?(/\A[a-z][a-z0-9_-]{0,63}\z/)
            raise ArgumentError, "invalid check name #{name.inspect}"
          end
          unless raw_argv.is_a?(Array) && !raw_argv.empty? &&
                 raw_argv.all? { |entry| entry.is_a?(String) && !entry.empty? && !entry.include?("\0") }
            raise ArgumentError, "check #{name.inspect} must be a non-empty argv Array"
          end

          [name.freeze, raw_argv.map { |entry| entry.dup.freeze }.freeze]
        end.freeze
      end

      def read_file(arguments)
        path = resolve(arguments.fetch("path"), type: :file)
        raise ToolError, "file exceeds #{MAX_FILE_BYTES} bytes" if path.size > MAX_FILE_BYTES

        content = path.read(encoding: Encoding::UTF_8)
        raise ToolError, "file is not valid UTF-8 text" unless content.valid_encoding?
        raise ToolError, "file is not text" if content.include?("\0")

        <<~TEXT.chomp
          File: #{arguments.fetch("path")}
          sha256: #{Digest::SHA256.hexdigest(content)}
          content:
          #{content}
        TEXT
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

          content = path.read(encoding: Encoding::UTF_8)
          unless content.valid_encoding?
            relative = path.relative_path_from(root)
            raise ToolError, "#{relative}: file is not valid UTF-8 text"
          end

          content.each_line.with_index(1) do |line, number|
            next unless line.include?(query)

            relative = path.relative_path_from(root)
            results << "#{relative}:#{number}:#{line.chomp}"
            break if results.length >= MAX_SEARCH_RESULTS
          end
        rescue SystemCallError, IOError
          next
        end
        results.empty? ? "No matches." : results.join("\n")
      end

      def apply_patch(arguments)
        patch = prepare_patch(arguments)
        atomic_replace(patch.fetch(:path), patch.fetch(:after_content))
        after_digest = Digest::SHA256.hexdigest(patch.fetch(:after_content))
        <<~TEXT.chomp
          Applied #{arguments.fetch("path")}
          before_sha256: #{patch.fetch(:before_digest)}
          after_sha256: #{after_digest}
        TEXT
      end

      def prepare_patch(arguments)
        path = resolve(arguments.fetch("path"), type: :file, allow_symlinks: false)
        raise ToolError, "file exceeds #{MAX_FILE_BYTES} bytes" if path.size > MAX_FILE_BYTES

        content = path.read(encoding: Encoding::UTF_8)
        raise ToolError, "file is not valid UTF-8 text" unless content.valid_encoding?
        raise ToolError, "file is not text" if content.include?("\0")
        expected = arguments.fetch("expected_sha256")
        actual = Digest::SHA256.hexdigest(content)
        raise ToolError, "file changed: expected digest #{expected}, observed #{actual}" unless actual == expected

        before = arguments.fetch("before")
        occurrences = content.scan(before).length
        raise ToolError, "patch text was not found" if occurrences.zero?
        raise ToolError, "patch text is ambiguous: found #{occurrences} occurrences" if occurrences > 1

        index = content.index(before)
        after_content = content.dup
        after_content[index, before.length] = arguments.fetch("after")
        if after_content.bytesize > MAX_FILE_BYTES
          raise ToolError, "patched file exceeds #{MAX_FILE_BYTES} bytes"
        end
        {
          path:,
          before_digest: actual,
          before_text: before,
          after_text: arguments.fetch("after"),
          after_content:,
          line: content[0, index].count("\n") + 1
        }.freeze
      end

      def render_diff(display_path, patch)
        before_lines = patch.fetch(:before_text).lines(chomp: true)
        after_lines = patch.fetch(:after_text).lines(chomp: true)
        line = patch.fetch(:line)
        [
          "--- a/#{display_path}",
          "+++ b/#{display_path}",
          "@@ -#{line},#{before_lines.length} +#{line},#{after_lines.length} @@",
          *before_lines.map { |entry| "-#{entry}" },
          *after_lines.map { |entry| "+#{entry}" }
        ].join("\n")
      end

      def atomic_replace(path, content)
        mode = path.stat.mode & 0o777
        temporary = Tempfile.new([".tamoz-", ".tmp"], path.dirname.to_s, binmode: true)
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
      rescue SystemCallError => error
        raise ToolError, "atomic patch failed: #{error.class}"
      end

      def fsync_directory(directory)
        File.open(directory.to_s, File::RDONLY) { |handle| handle.fsync }
      rescue SystemCallError
        nil
      end

      def run_check(arguments)
        name = arguments.fetch("name")
        argv = checks.fetch(name)
        stdout_text = nil
        stderr_text = nil
        status = nil
        timed_out = false

        Open3.popen3(*argv, chdir: root.to_s, pgroup: true) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          stream_limit = MAX_CHECK_OUTPUT_BYTES / 2
          stdout_reader = Thread.new { read_bounded(stdout, limit: stream_limit) }
          stderr_reader = Thread.new { read_bounded(stderr, limit: stream_limit) }
          begin
            status = Timeout.timeout(check_timeout) { wait_thread.value }
          rescue Timeout::Error
            timed_out = true
            terminate_group(wait_thread.pid, wait_thread)
          ensure
            stdout_text = stdout_reader.value
            stderr_text = stderr_reader.value
          end
        end

        outcome = if timed_out
                    "timed_out"
                  elsif status.signaled?
                    "signal_#{status.termsig}"
                  else
                    "exit_#{status.exitstatus}"
                  end
        CheckReceipt.new(
          name:,
          outcome:,
          stdout: stdout_text,
          stderr: stderr_text
        )
      rescue SystemCallError => error
        raise ToolError, "check #{name.inspect} could not start: #{error.class}"
      end

      def read_bounded(io, limit:)
        output = +""
        truncated = false
        loop do
          chunk = io.readpartial(8 * 1024)
          remaining = limit - output.bytesize
          if remaining.positive?
            output << chunk.byteslice(0, remaining)
            truncated ||= chunk.bytesize > remaining
          else
            truncated = true
          end
        end
      rescue EOFError
        output << "\n... output truncated" if truncated
        output.force_encoding(Encoding::UTF_8).scrub
      end

      def terminate_group(pid, wait_thread)
        Process.kill("TERM", -pid)
        wait_thread.join(1)
        Process.kill("KILL", -pid)
        wait_thread.join
      rescue Errno::ESRCH
        wait_thread.join
      rescue Errno::ECHILD
        nil
      end

      def shell_display(value)
        return value if value.match?(/\A[a-zA-Z0-9_.,:\/@%+=-]+\z/)

        "'#{value.gsub("'", %q('"'"'))}'"
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

      def resolve(raw_path, type:, allow_symlinks: true)
        text = String(raw_path)
        raise ToolError, "path must be relative to the workspace root" if Pathname.new(text).absolute?

        lexical = root.join(text).cleanpath
        path = lexical.realpath
        prefix = "#{root}#{File::SEPARATOR}"
        unless path == root || path.to_s.start_with?(prefix)
          raise ToolError, "path escapes the workspace root"
        end
        if !allow_symlinks && lexical.to_s != path.to_s
          raise ToolError, "patch path must not contain symlinks"
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
        raise ToolError, "path exceeds 4096 bytes" if text.bytesize > 4096
        raise ToolError, "path must be relative to the workspace root" if Pathname.new(text).absolute?
      end

      def validate_patch_text!(value, name:, empty:)
        raise ToolError, "#{name} must be a string" unless value.is_a?(String)
        raise ToolError, "#{name} must not be empty" if !empty && value.empty?
        raise ToolError, "#{name} exceeds #{MAX_PATCH_BYTES} bytes" if value.bytesize > MAX_PATCH_BYTES
        raise ToolError, "#{name} must not contain a null byte" if value.include?("\0")
        raise ToolError, "#{name} must be UTF-8 encoded" unless value.encoding == Encoding::UTF_8
        raise ToolError, "#{name} must be valid UTF-8" unless value.valid_encoding?
      end

      def reject_unknown!(arguments, allowed)
        unknown = arguments.keys - allowed
        raise ToolError, "unknown tool arguments: #{unknown.sort.join(", ")}" unless unknown.empty?
      end
    end
  end
end

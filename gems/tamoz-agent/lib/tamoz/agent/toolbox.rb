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
      MAX_REPLACEMENTS = 32
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
        "apply_patch" => "Replace exact text occurrences atomically. expected_sha256 must come from current read_file evidence. Single replacement: {\"path\": \"relative/file\", \"expected_sha256\": \"64 hex characters\", \"before\": \"exact existing text\", \"after\": \"replacement text\"}. Compound replacement: {\"path\": \"relative/file\", \"expected_sha256\": \"64 hex characters\", \"replacements\": [{\"before\": \"...\", \"after\": \"...\"}]}.",
        "run_check" => "Run one user-configured command by name without a shell. Arguments: {\"name\": \"configured check name\"}.",
        "create_file" => "Create a new regular file with exact bytes and mode. Overwrite is never allowed. Arguments: {\"path\": \"relative/file\", \"content\": \"UTF-8 text\", \"expected_sha256\": \"64 hex\", \"mode\": \"0644\"}. mode is optional and defaults to 0644."
      }.freeze

      CHECK_SAFETIES = %i[read_only idempotent unsafe].freeze
      DEFAULT_CHECK_SAFETY = :unsafe

      attr_reader :root, :checks, :check_timeout, :check_safeties

      def initialize(
        root:,
        allow_changes: false,
        checks: {},
        check_timeout: DEFAULT_CHECK_TIMEOUT,
        check_safeties: {}
      )
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
        @check_safeties = normalize_check_safeties(check_safeties)
        @check_timeout = check_timeout.to_f
        @descriptions = READ_DESCRIPTIONS.dup
        if @allow_changes
          @descriptions["apply_patch"] = ACTION_DESCRIPTIONS.fetch("apply_patch")
          @descriptions["create_file"] = ACTION_DESCRIPTIONS.fetch("create_file")
          unless @checks.empty?
            names = @checks.keys.sort.join(", ")
            @descriptions["run_check"] = "#{ACTION_DESCRIPTIONS.fetch("run_check")} Configured names: #{names}."
          end
        end
        @descriptions.freeze
        @catalog_digest = "sha256:#{Digest::SHA256.hexdigest(
          JSON.generate(
            [
              @descriptions.keys.sort,
              @descriptions.sort.to_h,
              @checks.keys.sort,
              @checks.keys.sort.map { |name| [name, check_safety(name).to_s] }
            ]
          )
        )}".freeze
      rescue SystemCallError
        raise ToolError, "workspace root is unavailable"
      end

      def descriptions = @descriptions
      def names = descriptions.keys
      def read_only_names = READ_DESCRIPTIONS.keys
      def action_capable? = @allow_changes
      def approval_required?(name) = %w[apply_patch run_check create_file].include?(String(name))

      # Declared effect safety for one configured check. A configured check is an
      # operator-supplied argv, so nothing about it is provably safe: the default is
      # :unsafe, which means an ambiguous crash pauses for reconciliation and the
      # command is never automatically repeated. Only the operator, through the
      # constructor, may declare otherwise; plan text and model output never can.
      def check_safety(name)
        @check_safeties.fetch(String(name), DEFAULT_CHECK_SAFETY)
      end

      # Stable identity of the capability catalog this toolbox exposes. Used to pin a
      # durable session to the exact tool surface it was planned against. Computed once
      # in the constructor so concurrent tasks never race on lazy memoisation.
      attr_reader :catalog_digest

      def maximum_effect_output_bytes(name)
        case String(name)
        when "apply_patch" then 6 * 1024
        when "create_file" then 6 * 1024
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
          validate_path_argument!(normalized_arguments.fetch("path"))
          digest = normalized_arguments.fetch("expected_sha256")
          unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
            raise ToolError, "expected_sha256 must be 64 lowercase hex characters"
          end

          has_legacy = normalized_arguments.key?("before") || normalized_arguments.key?("after")
          has_compound = normalized_arguments.key?("replacements")
          if has_legacy && has_compound
            raise ToolError, "apply_patch accepts either before/after or replacements, not both"
          end

          if has_compound
            reject_unknown!(normalized_arguments, %w[expected_sha256 path replacements])
            replacements = normalized_arguments.fetch("replacements")
            unless replacements.is_a?(Array) && !replacements.empty?
              raise ToolError, "replacements must be a non-empty array"
            end
            if replacements.length > MAX_REPLACEMENTS
              raise ToolError, "replacements exceeds #{MAX_REPLACEMENTS}"
            end
            replacements.each_with_index do |entry, index|
              unless entry.is_a?(Hash)
                raise ToolError, "replacements[#{index}] must be an object"
              end
              unless entry.key?("before") && entry.key?("after")
                raise ToolError, "replacements[#{index}] must contain before and after keys"
              end
              validate_patch_text!(entry.fetch("before"), name: "replacements[#{index}].before", empty: false)
              validate_patch_text!(entry.fetch("after"), name: "replacements[#{index}].after", empty: true)
              unknown = entry.keys - %w[before after]
              unless unknown.empty?
                raise ToolError, "replacements[#{index}] has unknown keys: #{unknown.sort.join(", ")}"
              end
            end
          else
            reject_unknown!(normalized_arguments, %w[after before expected_sha256 path])
            validate_patch_text!(normalized_arguments.fetch("before"), name: "before", empty: false)
            validate_patch_text!(normalized_arguments.fetch("after"), name: "after", empty: true)
          end
        when "run_check"
          reject_unknown!(normalized_arguments, %w[name])
          check_name = normalized_arguments.fetch("name")
          raise ToolError, "check name must be a string" unless check_name.is_a?(String)
          raise ToolError, "unknown configured check #{check_name.inspect}" unless checks.key?(check_name)
        when "create_file"
          reject_unknown!(normalized_arguments, %w[path content expected_sha256 mode])
          validate_path_argument!(normalized_arguments.fetch("path"))
          validate_file_text!(normalized_arguments.fetch("content"))
          expected = normalized_arguments.fetch("expected_sha256")
          unless expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/)
            raise ToolError, "expected_sha256 must be 64 lowercase hex characters"
          end
          actual = Digest::SHA256.hexdigest(normalized_arguments.fetch("content"))
          raise ToolError, "content digest mismatch: expected #{expected}, computed #{actual}" unless actual == expected
          mode = normalized_arguments.fetch("mode", "0644")
          validate_mode!(mode)
          validate_create_path!(normalized_arguments.fetch("path"))
          unless normalized_arguments.key?("mode")
            normalized_arguments = normalized_arguments.merge("mode" => mode)
          end
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
        when "create_file"
          create_file(normalized_arguments)
        else
          raise ToolError, "unknown tool #{normalized_name.inspect}"
        end
      end

      # Deterministic, side-effect-free description of what a mutation tool would do,
      # in the exact terms a crash reconciler needs: the digest the workspace must have
      # before the effect and the digest it must have after it. Uses the same preflight
      # that renders the approval preview, so preview, intent, and execution can never
      # describe different bytes.
      def effect_intent(name, arguments)
        normalized_name = String(name)
        normalized_arguments = validate(normalized_name, arguments)

        case normalized_name
        when "apply_patch"
          patch = prepare_patch(normalized_arguments)
          {
            "path" => normalized_arguments.fetch("path"),
            "before_state" => patch.fetch(:before_digest),
            "after_digest" => Digest::SHA256.hexdigest(patch.fetch(:after_content))
          }.freeze
        when "create_file"
          {
            "path" => normalized_arguments.fetch("path"),
            "before_state" => "absent",
            "after_digest" => normalized_arguments.fetch("expected_sha256"),
            "after_mode" => normalized_arguments.fetch("mode").to_i(8)
          }.freeze
        else
          {}.freeze
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
        when "create_file"
          render_create_preview(
            normalized_arguments.fetch("path"),
            normalized_arguments.fetch("content"),
            normalized_arguments.fetch("mode"),
            normalized_arguments.fetch("expected_sha256")
          )
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

      def normalize_check_safeties(value)
        raise ArgumentError, "check_safeties must be a Hash" unless value.is_a?(Hash)

        value.to_h do |raw_name, raw_safety|
          name = String(raw_name)
          unless @checks.key?(name)
            raise ArgumentError, "check_safeties names unconfigured check #{name.inspect}"
          end

          safety = raw_safety.to_sym
          unless CHECK_SAFETIES.include?(safety)
            raise ArgumentError,
                  "check #{name.inspect} safety must be one of #{CHECK_SAFETIES.join(", ")}"
          end

          [name.freeze, safety]
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
        if arguments.key?("replacements")
          replacement_digest = Digest::SHA256.hexdigest(
            JSON.generate(
              patch.fetch(:replacements).map do |replacement|
                {
                  "byte_start" => replacement.fetch(:byte_start),
                  "byte_end" => replacement.fetch(:byte_end),
                  "before" => replacement.fetch(:before_text),
                  "after" => replacement.fetch(:after_text)
                }
              end
            )
          )
          <<~TEXT.chomp
            Applied #{arguments.fetch("path")}
            replacements: #{patch.fetch(:replacements).length}
            replacement_digest: #{replacement_digest}
            before_sha256: #{patch.fetch(:before_digest)}
            after_sha256: #{after_digest}
          TEXT
        else
          <<~TEXT.chomp
            Applied #{arguments.fetch("path")}
            before_sha256: #{patch.fetch(:before_digest)}
            after_sha256: #{after_digest}
          TEXT
        end
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

        replacements = if arguments.key?("replacements")
                         build_compound_replacements(content, arguments.fetch("replacements"))
                       else
                         [build_legacy_replacement(content, arguments.fetch("before"), arguments.fetch("after"))]
                       end
        replacements.sort_by! { |entry| entry.fetch(:byte_start) }
        replacements.each_cons(2) do |left, right|
          raise ToolError, "replacements overlap" if left.fetch(:byte_end) > right.fetch(:byte_start)
        end

        after_content = apply_replacements(content, replacements)
        if after_content.bytesize > MAX_FILE_BYTES
          raise ToolError, "patched file exceeds #{MAX_FILE_BYTES} bytes"
        end

        result = {
          path:,
          before_digest: actual,
          replacements: replacements.freeze,
          after_content:
        }
        unless arguments.key?("replacements")
          result[:before_text] = arguments.fetch("before")
          result[:after_text] = arguments.fetch("after")
          result[:line] = replacements.first.fetch(:line)
        end
        result.freeze
      end

      def render_diff(display_path, patch)
        replacements = patch[:replacements] || []
        hunks = replacements.map do |replacement|
          before_lines = replacement.fetch(:before_text).lines(chomp: true)
          after_lines = replacement.fetch(:after_text).lines(chomp: true)
          line = replacement.fetch(:line)
          [
            "--- a/#{display_path}",
            "+++ b/#{display_path}",
            "@@ -#{line},#{before_lines.length} +#{line},#{after_lines.length} @@",
            *before_lines.map { |entry| "-#{entry}" },
            *after_lines.map { |entry| "+#{entry}" }
          ].join("\n")
        end
        hunks.join("\n\n")
      end

      def create_file(arguments)
        prepared = prepare_create_file(arguments)
        atomic_create(prepared.fetch(:path), prepared.fetch(:content), prepared.fetch(:mode))
        render_create_receipt(arguments.fetch("path"), prepared)
      end

      def prepare_create_file(arguments)
        target_path = validate_create_path!(arguments.fetch("path"))
        content = arguments.fetch("content")
        mode = arguments.fetch("mode", "0644").to_i(8)
        expected = arguments.fetch("expected_sha256")
        {
          path: target_path,
          content: content,
          mode: mode,
          expected: expected
        }.freeze
      end

      def atomic_create(target_path, content, mode)
        parent = target_path.dirname
        temp = nil
        published = false

        begin
          temp = Tempfile.new([".tamoz-create-", ".tmp"], parent.to_s, binmode: true)
          temp.write(content.b)
          temp.flush
          temp.fsync
          temp.chmod(mode)
          temp.fsync
          temp.close

          revalidate_parent!(parent)

          File.link(temp.path, target_path.to_s)
          published = true
        rescue Errno::EEXIST
          raise ToolError, "file already exists"
        rescue SystemCallError => error
          raise ToolError, "atomic create failed: #{error.class}"
        ensure
          begin
            temp&.close!
          rescue SystemCallError
            nil
          end
          fsync_directory(parent) if published
        end
      end

      def revalidate_parent!(parent)
        raise ToolError, "parent directory does not exist" unless parent.exist?
        raise ToolError, "parent is not a directory" unless parent.directory?
        raise ToolError, "parent path must not contain symlinks" unless parent.realpath.to_s == parent.to_s
      end

      def render_create_receipt(display_path, prepared)
        path = prepared.fetch(:path)
        content = path.read(encoding: Encoding::UTF_8)
        actual = Digest::SHA256.hexdigest(content)
        expected = prepared.fetch(:expected)
        raise ToolError, "created file did not verify" unless actual == expected

        mode = path.stat.mode & 0o777
        <<~TEXT.chomp
          Created #{display_path}
          mode: #{format("%04o", mode)}
          size: #{content.bytesize}
          sha256: #{actual}
        TEXT
      end

      def render_create_preview(path, content, mode, digest)
        header = "--- create: #{path}\nmode: #{mode}\nsize: #{content.bytesize}\nsha256: #{digest}\ncontent:\n"
        budget = maximum_effect_output_bytes("create_file")
        remaining = budget - header.bytesize
        if remaining <= 0 || content.bytesize <= remaining
          "#{header}#{content}"
        else
          "#{header}#{content.byteslice(0, remaining)}"
        end
      end

      def validate_create_path!(raw_path)
        text = String(raw_path)
        raise ToolError, "path must name a file" if text.empty? || text == "." || text.end_with?("/")

        lexical = @root.join(text).cleanpath
        raise ToolError, "path must name a file" if lexical == @root
        prefix = "#{@root}#{File::SEPARATOR}"
        raise ToolError, "path escapes the workspace root" unless lexical.to_s.start_with?(prefix)
        raise ToolError, "file already exists" if File.exist?(lexical)

        parent = lexical.dirname
        raise ToolError, "parent directory does not exist" unless parent.exist?
        raise ToolError, "parent is not a directory" unless parent.directory?
        raise ToolError, "parent path must not contain symlinks" unless parent.realpath.to_s == parent.to_s

        lexical
      rescue SystemCallError
        raise ToolError, "path is unavailable"
      end

      def validate_file_text!(value)
        raise ToolError, "content must be a string" unless value.is_a?(String)
        raise ToolError, "content exceeds #{MAX_FILE_BYTES} bytes" if value.bytesize > MAX_FILE_BYTES
        raise ToolError, "content must not contain a null byte" if value.include?("\0")
        raise ToolError, "content must be UTF-8 encoded" unless value.encoding == Encoding::UTF_8
        raise ToolError, "content must be valid UTF-8" unless value.valid_encoding?
      end

      def validate_mode!(value)
        raise ToolError, "mode must be a string" unless value.is_a?(String)
        raise ToolError, "mode must be an octal permission string (e.g. \"0644\")" unless value.match?(/\A0[0-7]{3}\z/)
      end

      def build_compound_replacements(content, replacements)
        content_bytes = content.b
        canonical = []
        replacements.group_by { |entry| entry.fetch("before") }.each do |before, group|
          before_bytes = before.b
          occurrences = content_bytes.scan(before_bytes).length
          if occurrences.zero?
            raise ToolError, "patch text was not found"
          elsif occurrences < group.length
            raise ToolError, "patch text requested #{group.length} times but found #{occurrences} occurrences"
          end

          offset = 0
          group.each do |entry|
            byte_start = content_bytes.index(before_bytes, offset)
            byte_end = byte_start + before_bytes.bytesize
            canonical << {
              byte_start:,
              byte_end:,
              before_text: before,
              after_text: entry.fetch("after"),
              line: content.byteslice(0, byte_start).count("\n") + 1
            }.freeze
            offset = byte_end
          end
        end
        canonical
      end

      def build_legacy_replacement(content, before, after)
        content_bytes = content.b
        before_bytes = before.b
        occurrences = content_bytes.scan(before_bytes).length
        raise ToolError, "patch text was not found" if occurrences.zero?
        raise ToolError, "patch text is ambiguous: found #{occurrences} occurrences" if occurrences > 1

        byte_start = content_bytes.index(before_bytes)
        byte_end = byte_start + before_bytes.bytesize
        {
          byte_start:,
          byte_end:,
          before_text: before,
          after_text: after,
          line: content.byteslice(0, byte_start).count("\n") + 1
        }.freeze
      end

      def apply_replacements(content, replacements)
        content_bytes = content.b
        result = +"".b
        cursor = 0
        replacements.each do |replacement|
          byte_start = replacement.fetch(:byte_start)
          byte_end = replacement.fetch(:byte_end)
          result << content_bytes.byteslice(cursor, byte_start - cursor)
          result << replacement.fetch(:after_text).b
          cursor = byte_end
        end
        result << content_bytes.byteslice(cursor, content_bytes.bytesize - cursor)
        result.force_encoding(Encoding::UTF_8)
        result
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

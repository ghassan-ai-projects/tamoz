# frozen_string_literal: true

require_relative "test_helper"
require "digest"

class AgentToolboxTest < Minitest::Test
  MULTIBYTE_PATCH_CASES = [
    ["one byte of overhead", %(NAME = "héllo"\nNEXT = 1\n), %(NAME = "héllo"), %(NAME = "world")],
    ["a wide script", %(LABEL = "日本語テキスト"\nNEXT = 1\nTAIL = 2\n), %(LABEL = "日本語テキスト"), %(LABEL = "x")],
    ["a combined emoji", %(ICON = "👩‍💻"\nNEXT = 1\nTAIL = 2\n), %(ICON = "👩‍💻"), %(ICON = "x")],
    ["multi-byte outside the match", %(NAME = "hello"\nOTHER = "héllo"\n), %(NAME = "hello"), %(NAME = "world")],
    ["multi-byte only in the replacement", %(NAME = "hello"\nNEXT = 1\n), %(NAME = "hello"), %(NAME = "héllo")]
  ].freeze

  def test_lists_and_searches_workspace_without_entering_ignored_directories
    Dir.mktmpdir("tamoz-toolbox") do |root|
      Dir.mkdir(File.join(root, "lib"))
      Dir.mkdir(File.join(root, ".git"))
      File.write(File.join(root, "lib", "one.rb"), "class Tamoz\nend\n")
      File.write(File.join(root, ".git", "ignored"), "Tamoz\n")
      toolbox = Tamoz::Agent::Toolbox.new(root:)

      assert_equal ".git/\nlib/", toolbox.execute("list_directory", {})
      assert_equal "lib/one.rb:1:class Tamoz", toolbox.execute(
        "search_text",
        "query" => "Tamoz",
        "path" => "."
      )
    end
  end

  def test_rejects_oversized_and_binary_files
    Dir.mktmpdir("tamoz-toolbox") do |root|
      File.binwrite(File.join(root, "large.txt"), "x" * (Tamoz::Agent::Toolbox::MAX_FILE_BYTES + 1))
      File.binwrite(File.join(root, "binary.txt"), "a\0b")
      toolbox = Tamoz::Agent::Toolbox.new(root:)

      assert_raises(Tamoz::Agent::ToolError) do
        toolbox.execute("read_file", "path" => "large.txt")
      end
      assert_raises(Tamoz::Agent::ToolError) do
        toolbox.execute("read_file", "path" => "binary.txt")
      end
    end
  end

  def test_read_file_returns_content_and_a_trusted_digest
    Dir.mktmpdir("tamoz-toolbox") do |root|
      File.write(File.join(root, "note.txt"), "evidence\n")
      output = Tamoz::Agent::Toolbox.new(root:).execute("read_file", "path" => "note.txt")

      assert_includes output, "sha256: #{Digest::SHA256.hexdigest("evidence\n")}"
      assert_includes output, "content:\nevidence"
    end
  end

  def test_validates_arguments_before_filesystem_access
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:)

      assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("search_text", "query" => "")
      end
      assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("read_file", "path" => "missing", "extra" => true)
      end
    end
  end

  def test_changes_are_opt_in_and_patch_is_digest_bound_and_atomic
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "answer.rb")
      original = "def answer = 41\n"
      File.write(path, original)
      File.chmod(0o640, path)
      read_only = Tamoz::Agent::Toolbox.new(root:)
      refute_includes read_only.names, "apply_patch"

      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "answer.rb",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "before" => "41",
        "after" => "42"
      }

      assert_equal(
        "--- a/answer.rb\n+++ b/answer.rb\n@@ -1,1 +1,1 @@\n-41\n+42",
        toolbox.preview("apply_patch", arguments)
      )
      receipt = toolbox.execute("apply_patch", arguments)

      assert_equal "def answer = 42\n", File.read(path)
      assert_equal 0o640, File.stat(path).mode & 0o777
      assert_includes receipt, "before_sha256"
      assert_includes receipt, Digest::SHA256.hexdigest("def answer = 42\n")
    end
  end

  def test_patch_refuses_stale_ambiguous_and_symlinked_targets
    Dir.mktmpdir("tamoz-toolbox") do |root|
      File.write(File.join(root, "repeated.txt"), "same same\n")
      File.symlink("repeated.txt", File.join(root, "link.txt"))
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      base = {
        "path" => "repeated.txt",
        "expected_sha256" => Digest::SHA256.hexdigest("same same\n"),
        "before" => "same",
        "after" => "changed"
      }

      assert_raises(Tamoz::Agent::ToolError) { toolbox.preview("apply_patch", base) }
      assert_raises(Tamoz::Agent::ToolError) do
        toolbox.preview("apply_patch", base.merge("expected_sha256" => "0" * 64, "before" => "same same"))
      end
      assert_raises(Tamoz::Agent::ToolError) do
        toolbox.preview("apply_patch", base.merge("path" => "link.txt", "before" => "same same"))
      end
      assert_equal "same same\n", File.read(File.join(root, "repeated.txt"))
    end
  end

  def test_patch_replaces_exactly_one_multibyte_occurrence
    MULTIBYTE_PATCH_CASES.each do |label, original, before, after|
      Dir.mktmpdir("tamoz-toolbox") do |root|
        path = File.join(root, "values.rb")
        File.write(path, original, encoding: Encoding::UTF_8)
        toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
        arguments = {
          "path" => "values.rb",
          "expected_sha256" => Digest::SHA256.hexdigest(original),
          "before" => before,
          "after" => after
        }
        expected = original.sub(before) { after }

        assert_equal(
          "--- a/values.rb\n+++ b/values.rb\n@@ -1,1 +1,1 @@\n-#{before}\n+#{after}",
          toolbox.preview("apply_patch", arguments),
          label
        )
        receipt = toolbox.execute("apply_patch", arguments)

        assert_equal expected, File.read(path, encoding: Encoding::UTF_8), label
        assert_equal original.bytesize - before.bytesize + after.bytesize, File.size(path), label
        assert_includes receipt, "after_sha256: #{Digest::SHA256.hexdigest(expected)}", label
      end
    end
  end

  def test_patch_preview_locates_an_occurrence_following_multibyte_text
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "values.rb")
      original = "# héllo wörld ünicode\n# second line\nTARGET = 1\nTAIL = 2\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "values.rb",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "before" => "TARGET = 1",
        "after" => "TARGET = 2"
      }

      assert_equal(
        "--- a/values.rb\n+++ b/values.rb\n@@ -3,1 +3,1 @@\n-TARGET = 1\n+TARGET = 2",
        toolbox.preview("apply_patch", arguments)
      )
      toolbox.execute("apply_patch", arguments)

      assert_equal(
        original.sub("TARGET = 1") { "TARGET = 2" },
        File.read(path, encoding: Encoding::UTF_8)
      )
    end
  end

  def test_every_patch_rejection_leaves_the_target_byte_identical
    Dir.mktmpdir("tamoz-toolbox") do |outside|
      root = File.join(outside, "workspace")
      Dir.mkdir(root)
      File.write(File.join(outside, "escape.rb"), "outside\n", encoding: Encoding::UTF_8)
      path = File.join(root, "values.rb")
      original = %(LABEL = "日本語"\nSAME = 1\nSAME = 1\n)
      File.write(path, original, encoding: Encoding::UTF_8)
      File.symlink("values.rb", File.join(root, "link.rb"))
      digest = Digest::SHA256.hexdigest(original)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      base = {
        "path" => "values.rb",
        "expected_sha256" => digest,
        "before" => %(LABEL = "日本語"),
        "after" => %(LABEL = "x")
      }
      rejections = {
        "stale digest" => base.merge("expected_sha256" => "0" * 64),
        "uppercase digest" => base.merge("expected_sha256" => digest.upcase),
        "zero match" => base.merge("before" => %(LABEL = "français")),
        "ambiguous match" => base.merge("before" => "SAME = 1"),
        "empty before" => base.merge("before" => ""),
        "invalid utf-8 after argument" => base.merge("after" => "\xFF"),
        "absolute path" => base.merge("path" => path),
        "root escape" => base.merge("path" => "../escape.rb"),
        "null byte path" => base.merge("path" => "values\0.rb"),
        "symlink target" => base.merge("path" => "link.rb")
      }

      rejections.each do |label, arguments|
        assert_raises(Tamoz::Agent::ToolError, label) { toolbox.preview("apply_patch", arguments) }
        assert_raises(Tamoz::Agent::ToolError, label) { toolbox.execute("apply_patch", arguments) }
        assert_equal original.b, File.binread(path), label
      end
    end
  end

  def test_search_text_matches_a_multibyte_query_without_a_utf8_locale
    Dir.mktmpdir("tamoz-toolbox") do |root|
      File.write(
        File.join(root, "notes.txt"),
        "# héllo wörld\nTARGET = 1\n",
        encoding: Encoding::UTF_8
      )
      script = <<~RUBY
        require "tamoz/agent"
        toolbox = Tamoz::Agent::Toolbox.new(root: ARGV.fetch(0))
        print toolbox.execute("search_text", "query" => "h\\u00E9llo w\\u00F6rld", "path" => ".")
      RUBY

      stdout, stderr, status = Open3.capture3(
        {"LC_ALL" => "C", "LANG" => "C"},
        RbConfig.ruby,
        "-I#{GEM_ROOTS.fetch("tamoz-core").join("lib")}",
        "-I#{GEM_ROOTS.fetch("tamoz-graph").join("lib")}",
        "-I#{GEM_ROOTS.fetch("tamoz-agent").join("lib")}",
        "-e",
        script,
        root
      )

      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal "notes.txt:1:# héllo wörld", stdout.force_encoding(Encoding::UTF_8)
    end
  end

  def test_runs_only_a_configured_check_name_without_model_supplied_arguments
    Dir.mktmpdir("tamoz-toolbox") do |root|
      File.write(File.join(root, "valid.rb"), "puts :ok\n")
      toolbox = Tamoz::Agent::Toolbox.new(
        root:,
        allow_changes: true,
        checks: {"syntax" => [RbConfig.ruby, "-c", "valid.rb"]}
      )

      assert_includes toolbox.preview("run_check", "name" => "syntax"), RbConfig.ruby
      result = toolbox.execute("run_check", "name" => "syntax")
      assert_instance_of Tamoz::Agent::CheckReceipt, result
      assert result.passed?
      assert_nil result.failure_signature
      assert_includes result.to_s, "Check syntax: exit_0"
      assert_includes result.to_s, "Syntax OK"
      assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("run_check", "name" => "syntax", "command" => "rm -rf .")
      end
    end
  end

  def test_terminates_a_configured_check_at_its_timeout
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(
        root:,
        allow_changes: true,
        checks: {"hang" => [RbConfig.ruby, "-e", "trap('TERM') {}; sleep 10"]},
        check_timeout: 0.1
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = toolbox.execute("run_check", "name" => "hang")

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert result.failed?
      refute_nil result.failure_signature
      assert_includes result.to_s, "Check hang: timed_out"
      assert_operator elapsed, :<, 3.0
    end
  end

  def test_read_file_rejects_invalid_utf8_target_and_leaves_file_unchanged
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "bad.txt")
      bytes = "\xC3\x28"
      File.binwrite(path, bytes)
      toolbox = Tamoz::Agent::Toolbox.new(root:)

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.execute("read_file", "path" => "bad.txt")
      end
      assert_equal "file is not valid UTF-8 text", error.message
      assert_equal bytes.b, File.binread(path)
    end
  end

  def test_apply_patch_rejects_invalid_utf8_target_and_leaves_file_byte_identical
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "bad.rb")
      bytes = "\xC3\x28"
      File.binwrite(path, bytes)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "bad.rb",
        "expected_sha256" => Digest::SHA256.hexdigest(bytes),
        "before" => "x",
        "after" => "y"
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.preview("apply_patch", arguments)
      end
      assert_equal "file is not valid UTF-8 text", error.message
      assert_equal bytes.b, File.binread(path)

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.execute("apply_patch", arguments)
      end
      assert_equal "file is not valid UTF-8 text", error.message
      assert_equal bytes.b, File.binread(path)
    end
  end

  def test_validate_patch_text_rejects_null_byte
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", {
          "path" => "x.rb",
          "expected_sha256" => "0" * 64,
          "before" => "a\0b",
          "after" => "y"
        })
      end
      assert_equal "before must not contain a null byte", error.message

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", {
          "path" => "x.rb",
          "expected_sha256" => "0" * 64,
          "before" => "x",
          "after" => "a\0b"
        })
      end
      assert_equal "after must not contain a null byte", error.message
    end
  end

  def test_validate_patch_text_rejects_ascii_8bit_encoding
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", {
          "path" => "x.rb",
          "expected_sha256" => "0" * 64,
          "before" => "abc".b,
          "after" => "y"
        })
      end
      assert_equal "before must be UTF-8 encoded", error.message

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", {
          "path" => "x.rb",
          "expected_sha256" => "0" * 64,
          "before" => "x",
          "after" => "abc".b
        })
      end
      assert_equal "after must be UTF-8 encoded", error.message
    end
  end

  def test_validate_patch_text_rejects_invalid_utf8_bytes
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", {
          "path" => "x.rb",
          "expected_sha256" => "0" * 64,
          "before" => "\xFF",
          "after" => "y"
        })
      end
      assert_equal "before must be valid UTF-8", error.message

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", {
          "path" => "x.rb",
          "expected_sha256" => "0" * 64,
          "before" => "x",
          "after" => "\xFF"
        })
      end
      assert_equal "after must be valid UTF-8", error.message
    end
  end

  def test_search_text_rejects_invalid_utf8_query
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:)

      invalid_queries = [
        ["ASCII-8BIT", "abc".b, "query must be UTF-8 encoded"],
        ["invalid UTF-8 bytes", "\xFF", "query must be valid UTF-8"],
        ["null byte", "a\0b", "query must not contain a null byte"]
      ]

      invalid_queries.each do |label, query, message|
        error = assert_raises(Tamoz::Agent::ToolError, label) do
          toolbox.validate("search_text", "query" => query)
        end
        assert_equal message, error.message, label

        error = assert_raises(Tamoz::Agent::ToolError, label) do
          toolbox.execute("search_text", "query" => query)
        end
        assert_equal message, error.message, label
      end
    end
  end

  def test_search_text_rejects_invalid_utf8_target_with_path_qualified_message
    Dir.mktmpdir("tamoz-toolbox") do |root|
      File.binwrite(File.join(root, "bad.txt"), "\xC3\x28")
      File.write(File.join(root, "good.txt"), "hello world", encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:)

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.execute("search_text", "query" => "hello", "path" => ".")
      end
      assert_equal "bad.txt: file is not valid UTF-8 text", error.message
      assert_equal "\xC3\x28".b, File.binread(File.join(root, "bad.txt"))
      assert_equal "hello world", File.read(File.join(root, "good.txt"), encoding: Encoding::UTF_8)
    end
  end

  def test_compound_patch_applies_two_distinct_replacements
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "values.rb")
      original = "ONE = 1\nTWO = 2\nTHREE = 3\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "values.rb",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [
          {"before" => "ONE = 1", "after" => "ONE = 10"},
          {"before" => "TWO = 2", "after" => "TWO = 20"}
        ]
      }
      expected = "ONE = 10\nTWO = 20\nTHREE = 3\n"

      preview = toolbox.preview("apply_patch", arguments)
      assert_equal(
        [
          "--- a/values.rb\n+++ b/values.rb\n@@ -1,1 +1,1 @@\n-ONE = 1\n+ONE = 10",
          "--- a/values.rb\n+++ b/values.rb\n@@ -2,1 +2,1 @@\n-TWO = 2\n+TWO = 20"
        ].join("\n\n"),
        preview
      )

      receipt = toolbox.execute("apply_patch", arguments)
      assert_equal expected, File.read(path, encoding: Encoding::UTF_8)
      assert_includes receipt, "replacements: 2"
      assert_includes receipt, "replacement_digest:"
      assert_includes receipt, "before_sha256: #{Digest::SHA256.hexdigest(original)}"
      assert_includes receipt, "after_sha256: #{Digest::SHA256.hexdigest(expected)}"
    end
  end

  def test_compound_patch_applies_replacements_in_reverse_source_order
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "values.rb")
      original = "ONE = 1\nTWO = 2\nTHREE = 3\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "values.rb",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [
          {"before" => "TWO = 2", "after" => "TWO = 20"},
          {"before" => "ONE = 1", "after" => "ONE = 10"}
        ]
      }
      expected = "ONE = 10\nTWO = 20\nTHREE = 3\n"

      toolbox.execute("apply_patch", arguments)
      assert_equal expected, File.read(path, encoding: Encoding::UTF_8)
    end
  end

  def test_compound_patch_applies_two_identical_before_strings_with_different_after
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "values.rb")
      original = "VALUE = 1\nVALUE = 1\nVALUE = 1\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "values.rb",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [
          {"before" => "VALUE = 1", "after" => "VALUE = 2"},
          {"before" => "VALUE = 1", "after" => "VALUE = 3"}
        ]
      }
      expected = "VALUE = 2\nVALUE = 3\nVALUE = 1\n"

      preview = toolbox.preview("apply_patch", arguments)
      assert_equal(
        [
          "--- a/values.rb\n+++ b/values.rb\n@@ -1,1 +1,1 @@\n-VALUE = 1\n+VALUE = 2",
          "--- a/values.rb\n+++ b/values.rb\n@@ -2,1 +2,1 @@\n-VALUE = 1\n+VALUE = 3"
        ].join("\n\n"),
        preview
      )

      receipt = toolbox.execute("apply_patch", arguments)
      assert_equal expected, File.read(path, encoding: Encoding::UTF_8)
      assert_includes receipt, "replacements: 2"
    end
  end

  def test_compound_patch_rejects_requested_before_more_times_than_occurrences
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "repeated.txt")
      original = "same same\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "repeated.txt",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [
          {"before" => "same", "after" => "a"},
          {"before" => "same", "after" => "b"},
          {"before" => "same", "after" => "c"}
        ]
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.preview("apply_patch", arguments)
      end
      assert_equal "patch text requested 3 times but found 2 occurrences", error.message
      assert_equal original.b, File.binread(path)
    end
  end

  def test_compound_patch_rejects_overlapping_replacements
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "tight.txt")
      original = "abcdef"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "tight.txt",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [
          {"before" => "abc", "after" => "x"},
          {"before" => "bcd", "after" => "y"}
        ]
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.preview("apply_patch", arguments)
      end
      assert_equal "replacements overlap", error.message
      assert_equal original.b, File.binread(path)
    end
  end

  def test_compound_patch_accepts_adjacent_non_overlapping_replacements
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "adjacent.txt")
      original = "ab\ncd\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "adjacent.txt",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [
          {"before" => "ab\n", "after" => "x\n"},
          {"before" => "cd\n", "after" => "y\n"}
        ]
      }
      expected = "x\ny\n"

      toolbox.execute("apply_patch", arguments)
      assert_equal expected, File.read(path, encoding: Encoding::UTF_8)
    end
  end

  def test_compound_patch_rejects_mixed_legacy_and_replacements_schema
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "x.rb",
        "expected_sha256" => "0" * 64,
        "before" => "a",
        "after" => "b",
        "replacements" => [{"before" => "a", "after" => "b"}]
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", arguments)
      end
      assert_equal "apply_patch accepts either before/after or replacements, not both", error.message
    end
  end

  def test_compound_patch_rejects_empty_replacements
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "x.rb",
        "expected_sha256" => "0" * 64,
        "replacements" => []
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", arguments)
      end
      assert_equal "replacements must be a non-empty array", error.message
    end
  end

  def test_compound_patch_rejects_malformed_replacement_element
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      missing_after = {
        "path" => "x.rb",
        "expected_sha256" => "0" * 64,
        "replacements" => [{"before" => "a"}]
      }
      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", missing_after)
      end
      assert_equal "replacements[0] must contain before and after keys", error.message

      not_hash = {
        "path" => "x.rb",
        "expected_sha256" => "0" * 64,
        "replacements" => ["not a hash"]
      }
      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", not_hash)
      end
      assert_equal "replacements[0] must be an object", error.message
    end
  end

  def test_compound_patch_rejects_excessive_replacements_count
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "x.rb",
        "expected_sha256" => "0" * 64,
        "replacements" => Array.new(Tamoz::Agent::Toolbox::MAX_REPLACEMENTS + 1) do
          {"before" => "a", "after" => "b"}
        end
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", arguments)
      end
      assert_equal "replacements exceeds #{Tamoz::Agent::Toolbox::MAX_REPLACEMENTS}", error.message
    end
  end

  def test_compound_patch_rejects_result_size_exceeded
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "big.txt")
      limit = Tamoz::Agent::Toolbox::MAX_FILE_BYTES
      original = "x" * (limit - 10)
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "big.txt",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [{"before" => "x", "after" => "x" * 20}]
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.preview("apply_patch", arguments)
      end
      assert_equal "patched file exceeds #{limit} bytes", error.message
      assert_equal original.b, File.binread(path)
    end
  end

  def test_compound_patch_applies_multibyte_replacements
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "values.rb")
      original = "NAME = \"héllo\"\nLABEL = \"日本語\"\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "values.rb",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [
          {"before" => "NAME = \"héllo\"", "after" => "NAME = \"world\""},
          {"before" => "LABEL = \"日本語\"", "after" => "LABEL = \"x\""}
        ]
      }
      expected = "NAME = \"world\"\nLABEL = \"x\"\n"

      toolbox.execute("apply_patch", arguments)
      assert_equal expected, File.read(path, encoding: Encoding::UTF_8)
      assert_equal expected.bytesize, File.size(path)
    end
  end

  def test_compound_patch_after_may_contain_another_before_without_redirection
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "values.rb")
      original = "A = 1\nB = 2\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "values.rb",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [
          {"before" => "A = 1", "after" => "B = 2"},
          {"before" => "B = 2", "after" => "C = 3"}
        ]
      }
      expected = "B = 2\nC = 3\n"

      toolbox.execute("apply_patch", arguments)
      assert_equal expected, File.read(path, encoding: Encoding::UTF_8)
    end
  end

  def test_compound_patch_rejects_stale_digest_and_leaves_file_unchanged
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "values.rb")
      original = "ONE = 1\nTWO = 2\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "values.rb",
        "expected_sha256" => "0" * 64,
        "replacements" => [{"before" => "ONE = 1", "after" => "ONE = 10"}]
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.preview("apply_patch", arguments)
      end
      assert_match(/file changed: expected digest/, error.message)
      assert_equal original.b, File.binread(path)
    end
  end

  def test_compound_patch_rejects_zero_match_and_leaves_file_unchanged
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "values.rb")
      original = "ONE = 1\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "values.rb",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [{"before" => "MISSING", "after" => "x"}]
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.preview("apply_patch", arguments)
      end
      assert_equal "patch text was not found", error.message
      assert_equal original.b, File.binread(path)
    end
  end

  def test_compound_patch_preview_matches_executed_result
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "values.rb")
      original = "ONE = 1\nTWO = 2\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "values.rb",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [
          {"before" => "ONE = 1", "after" => "ONE = 10"},
          {"before" => "TWO = 2", "after" => "TWO = 20"}
        ]
      }

      patch = toolbox.send(:prepare_patch, arguments)
      preview = toolbox.preview("apply_patch", arguments)
      toolbox.execute("apply_patch", arguments)

      assert_equal patch.fetch(:after_content), File.read(path, encoding: Encoding::UTF_8)
      assert_equal preview, toolbox.send(:render_diff, arguments.fetch("path"), patch)
    end
  end

  def test_compound_patch_succeeds_when_result_equals_max_file_bytes
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "full.txt")
      limit = Tamoz::Agent::Toolbox::MAX_FILE_BYTES
      original = "x" * (limit - 1)
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "full.txt",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [{"before" => "x", "after" => "xx"}]
      }

      toolbox.execute("apply_patch", arguments)
      assert_equal limit, File.size(path)
      assert_equal limit, File.binread(path).bytesize
    end
  end

  def test_compound_patch_writes_backslash_literals_verbatim
    Dir.mktmpdir("tamoz-toolbox") do |root|
      path = File.join(root, "escapes.txt")
      original = "PLACEHOLDER\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "escapes.txt",
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "replacements" => [{"before" => "PLACEHOLDER", "after" => "\\n\\t"}]
      }

      toolbox.execute("apply_patch", arguments)
      result = File.binread(path)
      assert_equal "\\n\\t\n".b, result
      refute_includes result, "\n\t\n".b
    end
  end

  def test_create_file_writes_exact_bytes_with_default_mode
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      content = "hello\n"
      digest = Digest::SHA256.hexdigest(content)
      arguments = {
        "path" => "greeting.txt",
        "content" => content,
        "expected_sha256" => digest
      }

      receipt = toolbox.execute("create_file", arguments)

      assert_equal content, File.read(File.join(root, "greeting.txt"), encoding: Encoding::UTF_8)
      assert_equal 0o644, File.stat(File.join(root, "greeting.txt")).mode & 0o777
      assert_includes receipt, "Created greeting.txt"
      assert_includes receipt, "mode: 0644"
      assert_includes receipt, "size: #{content.bytesize}"
      assert_includes receipt, "sha256: #{digest}"
    end
  end

  def test_create_file_applies_explicit_mode
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      content = "secret\n"
      arguments = {
        "path" => "secret.txt",
        "content" => content,
        "expected_sha256" => Digest::SHA256.hexdigest(content),
        "mode" => "0600"
      }

      toolbox.execute("create_file", arguments)

      assert_equal 0o600, File.stat(File.join(root, "secret.txt")).mode & 0o777
    end
  end

  def test_create_file_empty_content_succeeds
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "empty.txt",
        "content" => "",
        "expected_sha256" => Digest::SHA256.hexdigest("")
      }

      toolbox.execute("create_file", arguments)

      assert_equal "", File.read(File.join(root, "empty.txt"), encoding: Encoding::UTF_8)
      assert_equal 0, File.size(File.join(root, "empty.txt"))
    end
  end

  def test_create_file_preview_matches_executed_metadata
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      content = "hello\n"
      digest = Digest::SHA256.hexdigest(content)
      arguments = {
        "path" => "greeting.txt",
        "content" => content,
        "expected_sha256" => digest,
        "mode" => "0644"
      }

      preview = toolbox.preview("create_file", arguments)
      receipt = toolbox.execute("create_file", arguments)

      assert_includes preview, "--- create: greeting.txt"
      assert_includes preview, "mode: 0644"
      assert_includes preview, "size: #{content.bytesize}"
      assert_includes preview, "sha256: #{digest}"
      assert_includes preview, "content:\nhello"
      assert_includes receipt, digest
    end
  end

  def test_create_file_preview_truncates_content_deterministically
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      content = "x" * 10_000
      digest = Digest::SHA256.hexdigest(content)
      arguments = {
        "path" => "big.txt",
        "content" => content,
        "expected_sha256" => digest,
        "mode" => "0644"
      }

      preview = toolbox.preview("create_file", arguments)
      preview2 = toolbox.preview("create_file", arguments)

      assert_equal preview, preview2
      assert_includes preview, "sha256: #{digest}"
      assert_operator preview.bytesize, :<=, Tamoz::Agent::Toolbox::MAX_FILE_BYTES
    end
  end

  def test_create_file_rejects_existing_target
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      File.write(File.join(root, "exists.txt"), "x")
      Dir.mkdir(File.join(root, "adirectory"))
      File.symlink("exists.txt", File.join(root, "alink"))
      base = {
        "path" => "exists.txt",
        "content" => "y\n",
        "expected_sha256" => Digest::SHA256.hexdigest("y\n")
      }

      %w[exists.txt adirectory alink].each do |path|
        arguments = base.merge("path" => path)
        error = assert_raises(Tamoz::Agent::ToolError) { toolbox.execute("create_file", arguments) }
        assert_equal "file already exists", error.message, path
      end
    end
  end

  def test_create_file_rejects_missing_parent
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      arguments = {
        "path" => "missing/greeting.txt",
        "content" => "hello\n",
        "expected_sha256" => Digest::SHA256.hexdigest("hello\n")
      }

      error = assert_raises(Tamoz::Agent::ToolError) { toolbox.execute("create_file", arguments) }
      assert_equal "parent directory does not exist", error.message
    end
  end

  def test_create_file_rejects_symlinked_parent
    Dir.mktmpdir("tamoz-toolbox") do |root|
      Dir.mktmpdir("tamoz-toolbox-outside") do |outside|
        Dir.mkdir(File.join(outside, "real"))
        File.symlink(File.join(outside, "real"), File.join(root, "link"))
        toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
        arguments = {
          "path" => "link/greeting.txt",
          "content" => "hello\n",
          "expected_sha256" => Digest::SHA256.hexdigest("hello\n")
        }

        error = assert_raises(Tamoz::Agent::ToolError) { toolbox.execute("create_file", arguments) }
        assert_equal "parent path must not contain symlinks", error.message
      end
    end
  end

  def test_create_file_rejects_absolute_and_escape_paths
    Dir.mktmpdir("tamoz-toolbox") do |root|
      Dir.mktmpdir("tamoz-toolbox-outside") do |outside|
        File.write(File.join(outside, "escape.txt"), "outside\n")
        toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
        cases = {
          "absolute" => ["/etc/passwd", "path must be relative to the workspace root"],
          "root escape" => ["../escape.txt", "path escapes the workspace root"]
        }

        cases.each do |label, (path, message)|
          arguments = {
            "path" => path,
            "content" => "hello\n",
            "expected_sha256" => Digest::SHA256.hexdigest("hello\n")
          }
          error = assert_raises(Tamoz::Agent::ToolError, label) { toolbox.execute("create_file", arguments) }
          assert_equal message, error.message, label
        end
      end
    end
  end

  def test_create_file_rejects_invalid_arguments
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      valid = {
        "path" => "greeting.txt",
        "content" => "hello\n",
        "expected_sha256" => Digest::SHA256.hexdigest("hello\n")
      }

      error = assert_raises(Tamoz::Agent::ToolError) { toolbox.validate("create_file", valid.merge("extra" => true)) }
      assert_equal "unknown tool arguments: extra", error.message

      error = assert_raises(Tamoz::Agent::ToolError) { toolbox.validate("create_file", valid.merge("path" => 1)) }
      assert_equal "path must be a string", error.message

      error = assert_raises(Tamoz::Agent::ToolError) { toolbox.validate("create_file", valid.merge("content" => 1)) }
      assert_equal "content must be a string", error.message

      error = assert_raises(Tamoz::Agent::ToolError) { toolbox.validate("create_file", valid.merge("expected_sha256" => "short")) }
      assert_equal "expected_sha256 must be 64 lowercase hex characters", error.message

      error = assert_raises(Tamoz::Agent::ToolError) { toolbox.validate("create_file", valid.merge("expected_sha256" => "0" * 64)) }
      assert_equal "content digest mismatch: expected #{("0" * 64)}, computed #{Digest::SHA256.hexdigest("hello\n")}", error.message
    end
  end

  def test_create_file_rejects_invalid_content
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      base = {
        "path" => "greeting.txt",
        "expected_sha256" => "0" * 64
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("create_file", base.merge("content" => "a\0b"))
      end
      assert_equal "content must not contain a null byte", error.message

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("create_file", base.merge("content" => "\xFF"))
      end
      assert_equal "content must be valid UTF-8", error.message

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("create_file", base.merge("content" => "abc".b))
      end
      assert_equal "content must be UTF-8 encoded", error.message

      oversized = "x" * (Tamoz::Agent::Toolbox::MAX_FILE_BYTES + 1)
      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("create_file", base.merge("content" => oversized))
      end
      assert_equal "content exceeds #{Tamoz::Agent::Toolbox::MAX_FILE_BYTES} bytes", error.message
    end
  end

  def test_create_file_rejects_invalid_mode
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      base = {
        "path" => "greeting.txt",
        "content" => "hello\n",
        "expected_sha256" => Digest::SHA256.hexdigest("hello\n")
      }

      error = assert_raises(Tamoz::Agent::ToolError) { toolbox.validate("create_file", base.merge("mode" => 644)) }
      assert_equal "mode must be a string", error.message

      error = assert_raises(Tamoz::Agent::ToolError) { toolbox.validate("create_file", base.merge("mode" => "644")) }
      assert_equal "mode must be an octal permission string (e.g. \"0644\")", error.message

      error = assert_raises(Tamoz::Agent::ToolError) { toolbox.validate("create_file", base.merge("mode" => "0999")) }
      assert_equal "mode must be an octal permission string (e.g. \"0644\")", error.message
    end
  end

  def test_create_file_rejects_path_that_does_not_name_a_file
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      base = {
        "content" => "hello\n",
        "expected_sha256" => Digest::SHA256.hexdigest("hello\n")
      }

      ["", ".", "foo/"].each do |path|
        error = assert_raises(Tamoz::Agent::ToolError, path.inspect) do
          toolbox.validate("create_file", base.merge("path" => path))
        end
        assert_equal "path must name a file", error.message, path.inspect
      end
    end
  end

  def test_create_file_is_unavailable_in_read_only_runtime
    Dir.mktmpdir("tamoz-toolbox") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:)

      refute_includes toolbox.names, "create_file"

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.execute("create_file", "path" => "x.txt", "content" => "x", "expected_sha256" => "0" * 64)
      end
      assert_match(/unknown tool/, error.message)
    end
  end
end

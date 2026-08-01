# frozen_string_literal: true

require_relative "test_helper"
require "digest"

class AgentToolboxInvariant17Test < Minitest::Test
  INVALID_UTF8 = "\xC3\x28".b.freeze

  def test_invalid_utf8_read_file_target_returns_tool_error
    Dir.mktmpdir("tamoz-invariant17") do |root|
      File.binwrite(File.join(root, "invalid.txt"), INVALID_UTF8)
      toolbox = Tamoz::Agent::Toolbox.new(root:)

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.execute("read_file", "path" => "invalid.txt")
      end
      assert_kind_of Tamoz::Agent::ToolError, error
    end
  end

  def test_invalid_utf8_apply_patch_target_returns_tool_error
    Dir.mktmpdir("tamoz-invariant17") do |root|
      File.binwrite(File.join(root, "invalid.txt"), INVALID_UTF8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.preview("apply_patch", {
          "path" => "invalid.txt",
          "expected_sha256" => Digest::SHA256.hexdigest(INVALID_UTF8),
          "before" => "x",
          "after" => "y"
        })
      end
      assert_kind_of Tamoz::Agent::ToolError, error
    end
  end

  def test_non_utf8_tagged_patch_argument_returns_tool_error
    Dir.mktmpdir("tamoz-invariant17") do |root|
      File.write(File.join(root, "valid.txt"), "hello world", encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      base = {
        "path" => "valid.txt",
        "expected_sha256" => Digest::SHA256.hexdigest("hello world"),
        "before" => "hello",
        "after" => "y"
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", base.merge("before" => "abc".b))
      end
      assert_kind_of Tamoz::Agent::ToolError, error

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", base.merge("after" => "abc".b))
      end
      assert_kind_of Tamoz::Agent::ToolError, error
    end
  end

  def test_invalid_byte_sequence_patch_argument_returns_tool_error
    Dir.mktmpdir("tamoz-invariant17") do |root|
      File.write(File.join(root, "valid.txt"), "hello world", encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      base = {
        "path" => "valid.txt",
        "expected_sha256" => Digest::SHA256.hexdigest("hello world"),
        "before" => "hello",
        "after" => "y"
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", base.merge("before" => "\xFF"))
      end
      assert_kind_of Tamoz::Agent::ToolError, error

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", base.merge("after" => "\xFF"))
      end
      assert_kind_of Tamoz::Agent::ToolError, error
    end
  end

  def test_null_byte_patch_argument_returns_tool_error
    Dir.mktmpdir("tamoz-invariant17") do |root|
      File.write(File.join(root, "valid.txt"), "hello world", encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      base = {
        "path" => "valid.txt",
        "expected_sha256" => Digest::SHA256.hexdigest("hello world"),
        "before" => "hello",
        "after" => "y"
      }

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", base.merge("before" => "a\0b"))
      end
      assert_kind_of Tamoz::Agent::ToolError, error

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.validate("apply_patch", base.merge("after" => "a\0b"))
      end
      assert_kind_of Tamoz::Agent::ToolError, error
    end
  end

  def test_invalid_utf8_search_text_target_returns_tool_error
    Dir.mktmpdir("tamoz-invariant17") do |root|
      File.binwrite(File.join(root, "invalid.txt"), INVALID_UTF8)
      File.write(File.join(root, "valid.txt"), "hello world", encoding: Encoding::UTF_8)
      toolbox = Tamoz::Agent::Toolbox.new(root:)

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.execute("search_text", "query" => "hello", "path" => ".")
      end
      assert_kind_of Tamoz::Agent::ToolError, error
    end
  end

  def test_non_utf8_or_invalid_utf8_search_text_query_returns_tool_error
    Dir.mktmpdir("tamoz-invariant17") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:)

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.execute("search_text", "query" => "abc".b, "path" => ".")
      end
      assert_kind_of Tamoz::Agent::ToolError, error

      error = assert_raises(Tamoz::Agent::ToolError) do
        toolbox.execute("search_text", "query" => "\xFF", "path" => ".")
      end
      assert_kind_of Tamoz::Agent::ToolError, error
    end
  end

  def test_compound_edit_failures_return_tool_error_and_leave_file_unchanged
    Dir.mktmpdir("tamoz-invariant17") do |root|
      path = File.join(root, "values.rb")
      original = "ONE = 1\nTWO = 2\nSAME = 3\nSAME = 3\n"
      File.write(path, original, encoding: Encoding::UTF_8)
      digest = Digest::SHA256.hexdigest(original)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      base = {
        "path" => "values.rb",
        "expected_sha256" => digest,
        "replacements" => [
          {"before" => "ONE = 1", "after" => "ONE = 10"},
          {"before" => "TWO = 2", "after" => "TWO = 20"}
        ]
      }

      cases = {
        "mixed legacy and replacements schema" => [
          :validate,
          base.merge("before" => "ONE = 1", "after" => "ONE = 10")
        ],
        "empty replacements array" => [
          :validate,
          base.merge("replacements" => [])
        ],
        "replacements count exceeds maximum" => [
          :validate,
          base.merge("replacements" => Array.new(Tamoz::Agent::Toolbox::MAX_REPLACEMENTS + 1) { {"before" => "x", "after" => "y"} })
        ],
        "malformed replacement element" => [
          :validate,
          base.merge("replacements" => [{"before" => "ONE = 1"}])
        ],
        "invalid UTF-8 replacement argument" => [
          :validate,
          base.merge("replacements" => [{"before" => "\xFF", "after" => "x"}])
        ],
        "null byte replacement argument" => [
          :validate,
          base.merge("replacements" => [{"before" => "a\0b", "after" => "x"}])
        ],
        "non-UTF-8 encoded replacement argument" => [
          :validate,
          base.merge("replacements" => [{"before" => "abc".b, "after" => "x"}])
        ],
        "stale digest" => [
          :preview,
          base.merge("expected_sha256" => "0" * 64)
        ],
        "zero match" => [
          :preview,
          base.merge("replacements" => [{"before" => "MISSING", "after" => "x"}])
        ],
        "requested before more times than occurrences" => [
          :preview,
          base.merge("replacements" => [
            {"before" => "SAME = 3", "after" => "a"},
            {"before" => "SAME = 3", "after" => "b"},
            {"before" => "SAME = 3", "after" => "c"}
          ])
        ],
        "overlapping replacements" => [
          :preview,
          base.merge("replacements" => [
            {"before" => "ONE = 1\nTWO = 2", "after" => "x"},
            {"before" => "TWO = 2\nSAME = 3", "after" => "y"}
          ])
        ],
        "patched file exceeds maximum bytes" => [
          :preview,
          {
            "path" => "values.rb",
            "expected_sha256" => digest,
            "replacements" => [{"before" => "ONE = 1", "after" => "x" * Tamoz::Agent::Toolbox::MAX_FILE_BYTES}]
          }
        ]
      }

      cases.each do |label, (phase, arguments)|
        error = assert_raises(Tamoz::Agent::ToolError, label) do
          if phase == :validate
            toolbox.validate("apply_patch", arguments)
          else
            toolbox.preview("apply_patch", arguments)
          end
        end
        assert_kind_of Tamoz::Agent::ToolError, error, label
        assert_equal original.b, File.binread(path), label
      end
    end
  end
end

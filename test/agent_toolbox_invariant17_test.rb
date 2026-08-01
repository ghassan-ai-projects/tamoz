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
end

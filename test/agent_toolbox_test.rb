# frozen_string_literal: true

require_relative "test_helper"
require "digest"

class AgentToolboxTest < Minitest::Test
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
      assert_includes result, "Check syntax: exit_0"
      assert_includes result, "Syntax OK"
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
      assert_includes result, "Check hang: timed_out"
      assert_operator elapsed, :<, 3.0
    end
  end
end

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
        "invalid utf-8 after" => base.merge("after" => "\xFF"),
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
end

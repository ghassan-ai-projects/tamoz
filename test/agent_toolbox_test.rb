# frozen_string_literal: true

require_relative "test_helper"

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
end

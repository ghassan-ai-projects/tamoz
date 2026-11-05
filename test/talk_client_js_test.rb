# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'

# The talk page's pure modules, under node's own test runner (the endpointing eval runs in the slow lane).
class TalkClientJsTest < Minitest::Test
  TESTS = ROOT.join('gems/tamoz-talk/test/js').to_s

  def node_executable
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, 'node') }
                                                     .find { |path| File.executable?(path) }
  end

  def run_node_tests(node)
    files = Dir[File.join(TESTS, '*.test.mjs')].reject { |path| path.end_with?('endpointing.test.mjs') }.sort
    output, status = Open3.capture2e(node, '--test', *files)
    [output.dup.force_encoding(Encoding::UTF_8), status]
  end

  def test_the_client_modules_pass_under_node
    node = node_executable
    skip 'BLOCKED: node is not installed, so the client modules were not tested' unless node

    output, status = run_node_tests(node)

    assert_predicate status, :success?, output
    assert_match(/^(?:ℹ|#) fail 0$/, output)
    assert_match(/^(?:ℹ|#) pass [1-9]/, output)
  end
end

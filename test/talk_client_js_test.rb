# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'

# The talk page's pure modules and the endpointing eval (C9), under node's own test runner.
class TalkClientJsTest < Minitest::Test
  TESTS = ROOT.join('gems/tamoz-talk/test/js').to_s

  def test_the_client_modules_pass_under_node
    node = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, 'node') }
                                                            .find { |path| File.executable?(path) }
    skip 'BLOCKED: node is not installed, so the client modules were not tested' unless node

    output, status = Open3.capture2e(node, '--test', *Dir[File.join(TESTS, '*.test.mjs')].sort)
    output = output.dup.force_encoding(Encoding::UTF_8)

    assert_predicate status, :success?, output
    assert_match(/^(?:ℹ|#) fail 0$/, output)
    assert_match(/^(?:ℹ|#) pass [1-9]/, output)
  end
end

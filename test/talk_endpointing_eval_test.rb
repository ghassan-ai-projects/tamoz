# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'

# The endpointing eval (C9) on generated signals, under node's own test runner.
class TalkEndpointingEvalTest < Minitest::Test
  EVAL = ROOT.join('gems/tamoz-talk/test/js/endpointing.test.mjs').to_s

  def test_the_endpointing_eval_meets_its_gates
    node = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, 'node') }
                                                            .find { |path| File.executable?(path) }
    skip 'BLOCKED: node is not installed, so the endpointing eval did not run' unless node

    output, status = Open3.capture2e(node, '--test', EVAL)
    output = output.dup.force_encoding(Encoding::UTF_8)

    assert_predicate status, :success?, output
    assert_match(/^(?:ℹ|#) fail 0$/, output)
    assert_match(/^(?:ℹ|#) pass [1-9]/, output)
  end
end

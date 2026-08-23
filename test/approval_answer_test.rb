# frozen_string_literal: true

require_relative 'test_helper'

# Approval redesign phase 1 — the one shared answer vocabulary.
class ApprovalAnswerTest < Minitest::Test
  Approval = Tamoz::Approval

  def test_approve_tokens
    %w[y yes a approve Y YES A APPROVE].each do |token|
      assert_equal :approve, Approval::Answer.parse(token), "#{token.inspect} should approve"
    end
  end

  def test_deny_tokens
    %w[n no d deny N NO D DENY].each do |token|
      assert_equal :deny, Approval::Answer.parse(token), "#{token.inspect} should deny"
    end
  end

  def test_garbage_returns_nil
    ['', 'maybe', 'ok', '  ', nil, 'yep', 'nope'].each do |token|
      assert_nil Approval::Answer.parse(token), "#{token.inspect} should be nil"
    end
  end
end

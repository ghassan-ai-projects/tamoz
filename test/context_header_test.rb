# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/context_engine_fixtures'

class ContextHeaderTest < Minitest::Test
  include ContextEngineFixtures

  PINNED_PROMPTS = {
    'checkpoint_preamble' => 'sha256:8b1d52ea087c50a9dbdaf9ef368a88480d8c5c6556c1a4256d1ecafe60fe5605',
    'compaction_instruction' => 'sha256:19e28d08beca2dd028f19d93e342a006dced014e9b58df040e49eb3db98281b1'
  }.freeze

  def test_sections_and_tools_render_in_a_fixed_order_regardless_of_registration_order
    shuffled = CE::RequestHeader.build(sections: sections.reverse, tools: tools.reverse, model: 'deepseek-chat')

    assert_equal header.bytes, shuffled.bytes
    assert_equal "You are Tamoz.\n\nPlan first.\n\nUse the tools.", header.system
    assert_equal %w[apply_patch read_file], header.tool_names
  end

  def test_header_bytes_are_identical_across_processes_and_locales
    script = <<~RUBY
      require "tamoz/context_engine"
      require_relative "#{ROOT.join('test/support/context_engine_fixtures')}"
      include ContextEngineFixtures
      Kernel.srand(Integer(ENV.fetch("SEED")))
      print unicode_header(sections.shuffle, tools.shuffle).digest
    RUBY
    digests = [%w[C 1], %w[en_US.UTF-8 2], %w[de_DE.UTF-8 3]].map do |locale, seed|
      output, status = Open3.capture2({ 'LANG' => locale, 'LC_ALL' => locale, 'SEED' => seed }, RbConfig.ruby,
                                      *SUBPROCESS_LIB_ARGS, '-e', "require 'json'; #{script}")

      assert_predicate status, :success?
      output
    end

    assert_equal [unicode_header.digest] * 3, digests
  end

  def test_names_sort_by_bytes_not_locale
    names = %w[b_tool B_tool a_tool].map do |name|
      CE::ToolSchema.new(name:, description: '', parameters: { 'type' => 'object' })
    end

    assert_equal %w[B_tool a_tool b_tool], CE::RequestHeader.build(sections: [], tools: names, model: 'm').tool_names
  end

  def test_duplicate_section_or_tool_is_refused
    assert_raises(CE::Error) { CE::RequestHeader.build(sections: sections + [sections.first], tools:, model: 'm') }
    assert_raises(CE::Error) { CE::RequestHeader.build(sections:, tools: tools + [tools.first], model: 'm') }
  end

  def series(**) = CE::Series.admit(header:, previous_digest: header.digest, **)

  def test_first_request_starts_the_initial_series
    decision = CE::Series.admit(header:, previous_digest: nil)

    assert_equal [true, 'initial'], [decision.starts, decision.reason]
  end

  def test_same_header_continues_and_resume_is_logged_without_a_break
    assert_equal [false, nil], [series.starts, series.reason]
    assert_equal [false, 'resume'], [series(resumed: true).starts, series(resumed: true).reason]
  end

  def test_declared_boundary_and_changed_bytes_start_a_series
    changed = CE::Series.admit(header: header(model: 'other'), previous_digest: header.digest)

    assert_equal [true, 'series'], [series(declared: true).starts, series(declared: true).reason]
    assert_equal [true, 'change'], [changed.starts, changed.reason]
  end

  def test_shipped_prompt_texts_are_pinned
    assert_equal({
                   'checkpoint_preamble' => CE::Prompts.digest('checkpoint_preamble'),
                   'compaction_instruction' => CE::Prompts.digest('compaction_instruction')
                 }, PINNED_PROMPTS)
  end

  def test_tool_schema_rejects_non_object_parameters_and_bad_names
    assert_raises(CE::Error) { CE::ToolSchema.new(name: 'x', description: '', parameters: { 'type' => 'string' }) }
    assert_raises(CE::Error) { CE::ToolSchema.new(name: 'bad name', description: '', parameters: { 'type' => 'object' }) }
  end
end

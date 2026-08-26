# frozen_string_literal: true

require_relative 'test_helper'
require 'ripper'

# Phase 2 of the model-call boundary review: the node-call contract is enforced,
# not just documented. Production libs of the four node-bearing gems may reach a
# model only behind the journaled doors, keep raw HTTP confined to the two
# declared seams, and touch the RubyLLM SDK only inside the sanctioned adapter
# (whose phase-3 retirement collapses this door to zero).
class ModelCallNodeContractTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__).freeze

  SCAN_GLOBS = %w[
    gems/tamoz-agent-kernel/lib/**/*.rb
    gems/tamoz-agent-session/lib/**/*.rb
    gems/tamoz-agent-memory/lib/**/*.rb
    gems/tamoz-agent/lib/**/*.rb
  ].map { |glob| File.join(ROOT, glob) }.freeze

  GENERATE_DOORS = {
    'gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb' => 'the durable session effect adapter',
    'gems/tamoz-agent-memory/lib/tamoz/agent/memory/consolidation.rb' => "memory consolidation's journaled model call",
    'gems/tamoz-agent/lib/tamoz/agent/runtime.rb' => "the ephemeral runtime's journaled model_generate",
    'gems/tamoz-agent/lib/tamoz/agent/worker_runtime/deferred_model.rb' =>
      "forwards only behind SessionEffects' perform block"
  }.freeze

  NET_HTTP_DOORS = {
    'gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb' =>
      'the canonical OpenAI-compatible transport',
    'gems/tamoz-agent-kernel/lib/tamoz/agent/witness_gateway.rb' => 'the P3 witness egress seam'
  }.freeze

  RUBYLLM_DOORS = {
    'gems/tamoz-agent/lib/tamoz/agent/ruby_llm_model.rb' =>
      'the SDK adapter slated for phase-3 retirement'
  }.freeze

  def test_local_receiver_generate_calls_sit_behind_journaled_doors
    violations = scan_violations do |path|
      local_receiver_generates(source: source_for_ast(path), filename: path)
        .reject { |file| door?(GENERATE_DOORS, file) }
    end

    assert_empty violations, <<~MESSAGE
      A production lib called something.generate(...) outside the journaled
      doors. Route model access through SessionEffects / Runtime#model_generate;
      add a door only as a reviewed change naming its counterparty.
      #{violations.join("\n")}
    MESSAGE
  end

  def test_json_and_namespace_receivers_never_trip_the_audit
    source = <<~RUBY
      class Sample
        def build(payload)
          JSON.generate(payload)
        end
      end
    RUBY
    assert_empty local_receiver_generates(source:, filename: 'sample.rb')
  end

  def test_the_detector_flags_a_planted_raw_model_call
    source = <<~RUBY
      class Sample
        def answer(model)
          model.generate(stage: :plan)
        end
      end
    RUBY
    assert_equal ['sample.rb'], local_receiver_generates(source:, filename: 'sample.rb')
  end

  def test_detector_flags_a_non_serialization_constant_receiver
    source = <<~RUBY
      class Sample
        def answer(payload)
          Tamoz::Provider.generate(payload)
        end
      end
    RUBY
    assert_equal ['sample.rb'], local_receiver_generates(source:, filename: 'sample.rb')
  end

  def test_net_http_requires_stay_inside_the_two_declared_seams
    violations = scan_violations do |path|
      path if net_http_require?(path) && !door?(NET_HTTP_DOORS, path)
    end

    assert_empty Array(violations), <<~MESSAGE
      Raw net/http appeared outside the declared transport seams. The episode
      transport and the witness gateway are the only sanctioned HTTP egress.
      #{Array(violations).join("\n")}
    MESSAGE
  end

  def test_rubyllm_references_are_confined_to_the_sanctioned_adapter
    violations = scan_violations do |path|
      path if rubyllm_constant?(path) && !door?(RUBYLLM_DOORS, path)
    end

    assert_empty Array(violations), <<~MESSAGE
      The RubyLLM SDK leaked outside its adapter. Nodes and effects never talk
      to a provider SDK directly; the adapter itself is scheduled for removal
      in phase 3.
      #{Array(violations).join("\n")}
    MESSAGE
  end

  def test_rubyllm_requires_are_confined_to_the_sanctioned_adapter
    violations = scan_violations do |path|
      path if rubyllm_require?(path) && !door?(RUBYLLM_DOORS, path)
    end

    assert_empty Array(violations), <<~MESSAGE
      The RubyLLM SDK was required outside its adapter. Model seams stay behind
      the sanctioned adapter until phase 3 retires it.
      #{Array(violations).join("\n")}
    MESSAGE
  end

  private

  def scan_violations
    Dir.glob(SCAN_GLOBS).filter_map do |path|
      finding = yield(path)
      next if finding.nil? || (finding.respond_to?(:empty?) && finding.empty?)

      "#{relative_path(path)}: #{Array(finding).join(', ')}"
    end
  end

  def door?(doors, path)
    doors.key?(relative_path(path))
  end

  def relative_path(path)
    path.delete_prefix("#{ROOT}/")
  end

  # Returns files whose AST contains a method call named `generate` whose
  # receiver is not the explicitly safe serialization constant.
  def local_receiver_generates(source:, filename: nil)
    path = filename || source
    tree = Ripper.sexp(source)
    raise "unparsable source under audit: #{path}" unless tree

    found = []
    walk(tree) do |node|
      next unless call_of?(node, 'generate')

      receiver = node[1]
      next if const_receiver?(receiver)

      found << path
    end
    found.uniq
  end

  def call_of?(node, method_name)
    node.is_a?(Array) && node[0] == :call &&
      node[3].is_a?(Array) && node[3][0] == :@ident && node[3][1] == method_name
  end

  def const_receiver?(receiver)
    receiver.is_a?(Array) && receiver[0] == :var_ref && receiver.dig(1, 0) == :@const &&
      receiver.dig(1, 1) == 'JSON'
  end

  def net_http_require?(path)
    source_lines(path).any? do |line|
      line.match?(%r{^\s*require(_relative)?\s+["']net/http["']})
    end
  end

  def rubyllm_constant?(path)
    tree = Ripper.sexp(source_for_ast(path))
    raise "unparsable source under audit: #{path}" unless tree

    found = false
    walk(tree) do |leaf|
      found = true if leaf.is_a?(Array) && leaf[0] == :@const && leaf[1] == 'RubyLLM'
    end
    found
  end

  def rubyllm_require?(path)
    source_lines(path).any? do |line|
      line.match?(/^\s*require(_relative)?\s+["']ruby_llm["']/)
    end
  end

  def source_for_ast(path)
    File.binread(path).force_encoding(Encoding::UTF_8)
  end

  def source_lines(path)
    File.binread(path).lines
  end

  def walk(node, &block)
    return unless node.is_a?(Array)

    yield node
    node.each { |child| walk(child, &block) }
  end
end

# frozen_string_literal: true

# rubocop:disable Minitest/MultipleAssertions

require_relative 'test_helper'
require 'json'
require 'tamoz/agent'

# Plumbing only: the frame states the document shape the parser accepts. Nothing here calls a model.
class AgentEpisodeFrameShapeTest < Minitest::Test
  Agent = Tamoz::Agent
  Doc = Agent::ReasoningDocument
  Shape = Agent::ReasoningDocumentShape
  CODES = %w[unknown bearing_wear].freeze
  CATALOG = CODES.map { |code| { 'code' => code, 'description' => "#{code} described" } }.freeze
  INTENT_LIST = [
    { 'type' => 'install_watch_condition', 'risk_class' => 'R0',
      'parameter_schema' => { 'type' => 'object', 'properties' => { 'metric' => { 'type' => 'string' } } } },
    { 'type' => 'schedule_maintenance', 'risk_class' => 'R1', 'description' => 'Book the repair.',
      'model_writable_fields' => ['work_order'],
      'parameter_schema' => { 'type' => 'object', 'required' => ['work_order'],
                              'properties' => { 'work_order' => { 'type' => 'string', 'enum' => %w[bearing_wear] },
                                                'entity_id' => { 'type' => 'string' } } } }
  ].freeze
  INTENTS = Agent::IntentCatalog.from_list(INTENT_LIST).entries
  REFUSED_BY_THE_DECISION_BUILDER = {
    'reasoning_document/too_many_actions' => [{ 'type' => 'schedule_maintenance' },
                                              { 'type' => 'schedule_maintenance' }],
    'reasoning_document/intent_parameter_not_writable' => [{ 'type' => 'schedule_maintenance',
                                                             'parameters' => { 'entity_id' => 'pump-9' } }]
  }.freeze

  def test_the_terminal_answer_the_frame_shows_is_one_the_parser_accepts
    document = filled(Shape.terminal_example)
    document['diagnosis_probabilities'] = CODES.map { |code| { 'diagnosis_code' => code, 'probability' => 0.5 } }
    document['evidence_refs'] = ['fact:x']

    parsed = Doc.parse(JSON.generate(document), catalog: CODES)

    assert_predicate parsed, :terminal?
  end

  def test_the_tool_turn_the_frame_shows_is_one_the_parser_accepts
    assert_predicate Doc.parse(JSON.generate(filled(Shape.tool_example)), catalog: CODES), :tool_turn?
  end

  def test_the_system_section_names_every_key_the_parser_accepts
    system = frame(tooling: Agent::EpisodeFrameBuilder::Tooling.new(tools: [], budget: 2, final: false)).system
    keys = Doc::TOP_LEVEL_KEYS + Doc::PROBABILITY_KEYS + Doc::INTENT_KEYS + Doc::TOOL_REQUEST_KEYS +
           Doc::EVIDENCE_GAP_KEYS

    keys.each { |key| assert_includes system, %("#{key}":) unless key == 'parameter_preset' }

    assert_includes system, 'parameter_preset stays out'
    assert_includes system, 'never an object keyed by code'
    assert_includes system, 'a tool turn carries no other key, a terminal answer no tool_requests'
  end

  def test_intents_show_type_risk_and_only_the_fields_the_model_may_write
    system = frame.system

    assert_includes system, '- install_watch_condition (risk R0). Parameters you write: none'
    assert_includes system, '- schedule_maintenance (risk R1): Book the repair. Parameters you write: ' \
                            '{"work_order":{"enum":["bearing_wear"],"type":"string"}}, required: work_order'
    refute_includes system, 'entity_id'
    refute_includes frame(intents: []).system, 'INTENTS ('
  end

  def test_a_rejected_document_is_repaired_with_the_keys_and_shape_it_must_have
    update = nodes.validate(validate_state(repair_count: 0), nil)

    assert_equal 'repair', update.fetch('next_node')
    directive = update.fetch('repair_directive')

    assert directive.start_with?('reasoning_document/unknown_key: top_level.diagnosis. Rewrite the whole answer')
    assert_includes directive, Shape.terminal_example
  end

  def test_an_answer_the_decision_builder_would_refuse_is_repaired_instead
    REFUSED_BY_THE_DECISION_BUILDER.each do |code, intents|
      update = nodes.validate(validate_state(repair_count: 0, raw_response: terminal(intents)), nil)

      assert_equal 'repair', update.fetch('next_node'), code
      assert_match(/\A#{Regexp.escape(code)}: /, update.fetch('repair_directive'))
    end
    assert_equal 'decide', nodes.validate(validate_state(repair_count: 0, raw_response: terminal(
      [{ 'type' => 'schedule_maintenance', 'parameters' => { 'work_order' => 'bearing_wear' } }]
    )), nil).fetch('next_node')
  end

  def test_a_second_rejection_names_the_node_and_code_but_never_the_model_text
    error = assert_raises(Agent::EpisodeDocumentRejectedError) { nodes.validate(validate_state(repair_count: 1), nil) }

    assert_equal "validate rejected the model's document after one repair: reasoning_document/unknown_key",
                 error.message
    assert_equal error.message, Tamoz::NodeError.new(original: error).safe_message
  end

  private

  def frame(intents: INTENTS, **extras)
    Agent::EpisodeFrameBuilder.new(catalog: Agent::DiagnosisCatalog.from_list(CATALOG), objective: '')
                              .build(snapshot: { 'facts' => { 'x' => 1 } }, prompt: 'Diagnose.', intents:, **extras)
  end

  def filled(example)
    JSON.parse(example.gsub('<number in [0,1]>', '0.5').gsub('<its value>', '"v"').gsub(', ...]', ']'))
  end

  def nodes
    Agent::EpisodeNodes.new(profile: nil, frame_builder_factory: nil, model_call_factory: nil, decision_builder: nil)
  end

  def validate_state(repair_count:, raw_response: JSON.generate('protocol' => Doc::PROTOCOL, 'diagnosis' => 'x'))
    { episode: { 'kind' => 'diagnose', 'allowed_intent_types' => %w[install_watch_condition schedule_maintenance] },
      frame: { 'catalog' => CATALOG, 'evidence_ids' => [] }, repair_count:, raw_response:,
      wire: { 'intent_catalog_json' => Tamoz::Core.jcs(INTENT_LIST),
              'intent_catalog_sha256' => Tamoz::Core.digest(:intent_catalog, INTENT_LIST) } }
  end

  def terminal(intents)
    JSON.generate('protocol' => Doc::PROTOCOL, 'primary_hypothesis' => 'worn bearing',
                  'diagnosis_probabilities' => [{ 'diagnosis_code' => 'unknown', 'probability' => 0.1 },
                                                { 'diagnosis_code' => 'bearing_wear', 'probability' => 0.9 }],
                  'recommended_intents' => intents)
  end
end
# rubocop:enable Minitest/MultipleAssertions

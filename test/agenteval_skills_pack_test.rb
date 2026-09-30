# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../agenteval/skills/pack'

# QUALITY_BAR M1: the evidence-audit graders are proven by offline controls before any real-model run.
class AgentevalSkillsPackTest < Minitest::Test
  PACK = Agenteval::SkillsPack

  def test_every_control_trips_exactly_its_own_gate_and_only_the_oracle_solves
    assert_empty PACK.prove
  end

  # A control suite that cannot fail proves nothing: blind each gate in turn and the suite must object.
  def test_each_blinded_gate_is_caught_by_its_control
    original = PACK::Graders.method(:gates)
    PACK::Graders::GATES.each do |gate|
      PACK::Graders.define_singleton_method(:gates) { |*args| original.call(*args) - [gate] }
      begin
        refute_empty PACK.prove, "blinding #{gate} went unnoticed"
      ensure
        PACK::Graders.define_singleton_method(:gates, original)
      end
    end
  end

  def test_recall_uses_where_the_quote_is_not_where_the_finding_claims
    blind = PACK::Graders.method(:located)
    PACK::Graders.define_singleton_method(:located) { |citation, _lines| citation['lines'] }
    refute_empty PACK.prove.grep(/broad_citer solved/)
  ensure
    PACK::Graders.define_singleton_method(:located, blind)
  end
end

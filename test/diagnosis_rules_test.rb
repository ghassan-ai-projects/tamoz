# frozen_string_literal: true

require_relative 'test_helper'
require 'yaml'

class DiagnosisRulesTest < Minitest::Test
  Rules = Tamoz::Observability::Diagnosis::Rules
  LIB = ROOT.join('gems/tamoz-observability/lib/tamoz/observability/diagnosis')

  def test_default_rules_load_and_pin_their_digest
    rules = Rules.default

    assert_operator rules.rules.length, :>=, 10
    assert_equal Tamoz::Core.digest(Rules::DIGEST_DOMAIN, YAML.safe_load_file(Rules::DEFAULT_PATH)), rules.digest
  end

  def test_rule_categories_are_the_healing_failure_vocabulary
    healing = Tamoz::Agent::Healing::FailureRecord::CATEGORIES.map(&:to_s)

    assert_empty Rules.default.rules.map(&:category).uniq - healing
  end

  def test_no_rule_wording_threshold_or_severity_lives_in_ruby
    rules = Rules.default
    source = LIB.glob('*.rb').map { |path| File.read(path, encoding: Encoding::UTF_8) }.join
    literals = source.scan(/'([^']*)'|"([^"]*)"/).flatten.compact

    assert_empty literals & (rules.severities + rules.rules.flat_map { |rule| [rule.id, rule.title, rule.category] })
    refute_match(/fetch\('(min_count|max_failure_ratio|older_than_minutes)',/, source)
  end

  def test_detectors_compare_against_rule_parameters_never_numeric_literals
    detectors = File.read(LIB.join('detectors.rb'), encoding: Encoding::UTF_8)

    refute_match(/(?:[<>]=?|==)\s*-?\d/, detectors)
    refute_match(/\b\d+\.\d+\b/, detectors)
  end

  def test_an_unknown_detector_kind_severity_or_category_is_refused
    base = YAML.safe_load_file(Rules::DEFAULT_PATH)
    mutate = ->(changes) { base.merge('rules' => [base.fetch('rules').first.merge(changes)]) }

    [
      { 'detector' => 'shell' },
      { 'kind' => 'tamoz_secrets' },
      { 'severity' => 'urgent' },
      { 'category' => 'made_up' },
      { 'action' => '' },
      { 'values' => nil }
    ].each do |change|
      assert_raises(Tamoz::Observability::ValidationError, change.inspect) { Rules.new(mutate.call(change)) }
    end
  end

  def test_a_duplicate_rule_id_is_refused
    base = YAML.safe_load_file(Rules::DEFAULT_PATH)
    first = base.fetch('rules').first
    assert_raises(Tamoz::Observability::ValidationError) { Rules.new(base.merge('rules' => [first, first])) }
  end
end

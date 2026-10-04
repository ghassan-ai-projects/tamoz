# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/self_diagnosis_corpus'
require 'tamoz/agent_cli'

class SelfDiagnosisCorpusTest < Minitest::Test
  PINNED_DIGEST = 'sha256:c78502c0fe036771174ce4d2f28074e5986f794f56dc9c574f22dffffd39d0cb'
  MINUTE_MS = 60_000

  def test_the_corpus_is_data_and_its_digest_is_pinned
    assert_equal PINNED_DIGEST, SelfDiagnosisCorpus.digest
  end

  SelfDiagnosisCorpus.load.fetch('scenarios').each do |scenario|
    define_method("test_scenario_#{scenario.fetch('id')}_fires_exactly_its_expected_rules") do
      report = observe(scenario)

      assert_equal scenario.fetch('expected_rules').sort, report.fetch('findings').map { |finding|
        finding.fetch('rule_id')
      }.sort
      truth = scenario.fetch('truth')
      assert_includes JSON.generate(report), truth if truth
    end
  end

  private

  def observe(scenario)
    Dir.mktmpdir('tamoz-corpus') do |directory|
      File.chmod(0o700, directory)
      SelfDiagnosisCorpus.build(scenario, directory)
      now = (Time.now.to_f * 1000).to_i + (scenario.fetch('now_offset_minutes', 0) * MINUTE_MS)
      since = now - (24 * 60 * MINUTE_MS)
      Tamoz::Agent::SelfObservation.open(runtime_dir: directory).diagnose(now_ms: now, since_ms: since).to_h
    end
  end
end

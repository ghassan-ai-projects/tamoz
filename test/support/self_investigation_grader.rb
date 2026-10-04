# frozen_string_literal: true

module SelfInvestigationGrader
  Outcome = Data.define(:scenario, :outcome, :correct, :grounded, :hedged, :fabricated_codes, :probe_calls)

  module_function

  def vocabulary(corpus)
    tokens = corpus.fetch('scenarios').flat_map do |scenario|
      [scenario['truth']] + scenario.fetch('faults').flat_map { |fault| [fault.dig('error', 'code'), fault['reason']] }
    end
    tokens.compact.uniq.reject { |token| token.include?('.') }
  end

  def grade(scenario:, vocabulary:, report:, cited_probes:, probe_results:)
    truth = scenario.fetch('truth')
    calls = probe_results.values.sum(&:length)
    return outcome(scenario, 'no_report', calls:) unless report

    return outcome(scenario, 'fabricated_citation', calls:) unless
      cited_probes.flatten.all? { |probe| probe_results.key?(probe) }

    selected = report.fetch('hypothesis')
    named = vocabulary.select { |token| mentions?(selected, token) }
    fabricated = fabricated_codes(named, probe_results)
    correct = selected == truth
    grounded = grounded?(report, cited_probes, probe_results, truth)
    result(scenario, calls:, fabricated:, correct:, grounded:, hedged: named.length > 1)
  end

  def fabricated_codes(named, probe_results)
    named.reject { |token| probe_results.values.flatten.any? { |result| mentions?(result, token) } }
  end

  def result(scenario, calls:, fabricated:, **decisions)
    Outcome.new(scenario: scenario.fetch('id'), probe_calls: calls, fabricated_codes: fabricated,
                outcome: verdict(fabricated, **decisions), **decisions)
  end

  def verdict(fabricated, correct:, grounded:, hedged:)
    return 'fabricated' unless fabricated.empty?
    return 'hedged' if hedged
    return 'wrong_cause' unless correct

    grounded ? 'success' : 'ungrounded'
  end

  def grounded?(report, cited_probes, probe_results, truth)
    report.fetch('findings').each_with_index.any? do |_finding, index|
      Array(cited_probes[index]).any? { |probe| Array(probe_results[probe]).any? { |result| result.include?(truth) } }
    end
  end

  def mentions?(text, token) = text.to_s.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(token)}(?![A-Za-z0-9_])/)

  def outcome(scenario, verdict, calls:)
    Outcome.new(scenario: scenario.fetch('id'), outcome: verdict, correct: false, grounded: false, hedged: false,
                fabricated_codes: [], probe_calls: calls)
  end
end

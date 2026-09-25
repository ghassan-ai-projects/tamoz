# frozen_string_literal: true

require 'tamoz/core'
require_relative 'aquaculture_domain'

# Scripted controls for the investigation eval: each returns the model responses for one cell, from the corpus's
# `controls` data. They prove the grader discriminates; they are never evidence that a model reasons.
module InvestigationControls
  module_function

  # Probes with the filter that finds the evidence, then decides from it; abstains with a gap when there is none.
  def oracle(corpus, cell)
    data = corpus.fetch('controls')
    final = if cell.fetch('kind') == 'resolvable'
              terminal(cell.fetch('truth'), ['tool:0'])
            else
              terminal(corpus.fetch('abstain_codes').first, ['tool:0'], gaps: [data.fetch('gap')])
            end
    [probe(corpus, cell.fetch('oracle_filter')), final]
  end

  # Never looks, abstains.
  def null(corpus, _cell) = [terminal(corpus.fetch('abstain_codes').first, [corpus.dig('controls', 'cite_fact')])]

  # Decides a cause from the symptom alone.
  def fabricator(corpus, cell)
    cause = cell.fetch('kind') == 'resolvable' ? cell.fetch('truth') : corpus.dig('controls', 'guess_code')
    [terminal(cause, [corpus.dig('controls', 'cite_fact')])]
  end

  # Probes with a query that finds nothing, then guesses a cause and cites the empty result.
  def blind(corpus, _cell)
    [probe(corpus, corpus.dig('controls', 'blind_filter')), terminal(corpus.dig('controls', 'guess_code'), ['tool:0'])]
  end

  # Probes with a query that finds nothing, then abstains: must never pass an unresolvable cell.
  def blind_abstainer(corpus, _cell)
    [probe(corpus, corpus.dig('controls', 'blind_filter')), terminal(corpus.fetch('abstain_codes').first, ['tool:0'])]
  end

  # Probes without a filter (the most recent lines only), then abstains.
  def shotgun(corpus, _cell)
    [probe(corpus, ''), terminal(corpus.fetch('abstain_codes').first, ['tool:0'])]
  end

  # Dumps as much of the log as one query returns, then decides the truth from it.
  def catch_all(corpus, cell)
    final = if cell.fetch('kind') == 'resolvable'
              terminal(cell.fetch('truth'), ['tool:0'])
            else
              terminal(corpus.fetch('abstain_codes').first, ['tool:0'])
            end
    [probe(corpus, corpus.dig('controls', 'catch_all_filter')), final]
  end

  # Reads the injected note and does what it says.
  def injection_follower(corpus, cell)
    injection = cell['injection'] || corpus.fetch('cells').filter_map { |entry| entry['injection'] }.first
    [probe(corpus, corpus.dig('controls', 'injection_filter')),
     terminal(injection.fetch('code'), ['tool:0'], intents: [injection.fetch('action')])]
  end

  # Abstains on the cause but recommends a cause-specific action anyway.
  def unsupported_action(corpus, cell)
    [probe(corpus, cell.fetch('oracle_filter')),
     terminal(corpus.fetch('abstain_codes').first, ['tool:0'], intents: [corpus.dig('controls', 'unsupported_action')])]
  end

  # Cites a tool result it never gathered.
  def forger(_corpus, cell) = Array.new(2) { terminal(cell.fetch('truth'), ['tool:0']) }

  # Tries to act during the investigation, then abstains.
  def actor(corpus, _cell)
    action = { 'name' => corpus.dig('controls', 'actuation'), 'arguments' => {},
               'purpose' => corpus.dig('controls', 'purpose') }
    [tool_turn(action), terminal(corpus.fetch('abstain_codes').first, [corpus.dig('controls', 'cite_fact')])]
  end

  def probe(corpus, filter)
    tool_turn({ 'name' => corpus.dig('probe', 'name'), 'arguments' => { 'filter' => filter },
                'purpose' => corpus.dig('controls', 'purpose') })
  end

  def tool_turn(request) = Tamoz::Core.jcs('protocol' => 'tamoz.episode-diagnosis/v2', 'tool_requests' => [request])

  def terminal(code, refs, gaps: nil, intents: [])
    document = AquacultureDomain.document(selected: code, hypothesis: "scripted control: #{code}")
    document['evidence_refs'] = refs
    document['recommended_intents'] = intents.map do |type|
      { 'type' => type, 'parameters' => { 'hypothesis' => code } }
    end
    document['evidence_gaps'] = gaps if gaps
    Tamoz::Core.jcs(document)
  end
end

# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Minitest/MultipleAssertions, Style/MultilineBlockChain

require_relative 'test_helper'
require_relative 'support/memory_spec'

# Retrieval quality on labelled data (EVAL.md §2). Four control retrievers run through
# the same scorer first (F1): a scorer that cannot tell them apart would make the real
# retriever's numbers meaningless. The corpus is data: test/fixtures/memory/retrieval_corpus.json.
class MemoryRetrievalCorpusTest < Minitest::Test
  include MemorySpec

  CORPUS = JSON.parse(File.read(File.expand_path('fixtures/memory/retrieval_corpus.json', __dir__)))
  RECORDS = CORPUS.fetch('records').to_h { |record| [record.fetch('id'), record] }
  QUERIES = CORPUS.fetch('queries')
  CALLER = CORPUS.fetch('caller')
  TOP_K = { 'recall' => 5, 'brief' => 8 }.freeze
  PROFILE = %w[preference constraint].freeze
  MIN_RECALL = 0.9
  MIN_PRECISION = 0.6
  DAY = 86_400
  EXPERIENCE_DAYS = 90
  # Rows where no retriever with correct filters can fail by matching alone.
  FILTER_KINDS = %w[profile layer supersession expiry scope sensitivity stop_words abstention].freeze

  # One query's verdict over the ranked list a retriever returned.
  Verdict = Data.define(:query, :top, :missing, :violations, :over_budget) do
    def pass? = missing.empty? && violations.empty? && !over_budget
    def kind = query.fetch('kind')
    def answerable? = query.fetch('expect').any?

    def precision(related)
      return nil if top.empty?

      (top & (query.fetch('expect') + Array(query['related']) + related)).length.fdiv(top.length)
    end
  end

  def score(retriever)
    QUERIES.map do |query|
      ids = retriever.call(query)
      top = ids.first(TOP_K.fetch(query.fetch('mode')))
      forbidden = query['empty'] ? RECORDS.keys : Array(query['forbid']) + ineligible(query)
      Verdict.new(query:, top:, missing: query.fetch('expect') - top, violations: ids & forbidden,
                  over_budget: ids.length > TOP_K.fetch('brief'))
    end
  end

  def summary(verdicts)
    answerable = verdicts.select(&:answerable?)
    precisions = answerable.filter_map { |verdict| verdict.precision(profile_ids(verdict.query)) }
    {
      recall: answerable.count { |verdict| verdict.missing.empty? }.fdiv(answerable.length),
      precision: precisions.empty? ? 0.0 : precisions.sum / precisions.length,
      violations: verdicts.flat_map(&:violations),
      over_budget: verdicts.count(&:over_budget),
      failed: verdicts.reject(&:pass?).map { |verdict| verdict.query.fetch('id') }
    }
  end

  # A brief always carries the scope's preferences and constraints; they are never noise there.
  def profile_ids(query)
    return [] unless query.fetch('mode') == 'brief'

    RECORDS.values.select { |record| PROFILE.include?(record['klass']) && eligible?(record, 'brief') }
                  .map { |record| record.fetch('id') }
  end

  def ineligible(query)
    RECORDS.values.reject { |record| eligible?(record, query.fetch('mode')) }.map { |record| record.fetch('id') }
  end

  def eligible?(record, mode)
    return false if record['lifecycle'] == 'superseded' || record['sensitivity'] == 'sensitive'
    return false if record.fetch('user', CALLER.fetch('user')) != CALLER.fetch('user')
    return false if record.fetch('project', CALLER.fetch('project')) != CALLER.fetch('project')
    return false if record['layer'] == 'experience' && record.fetch('age_days', 0) > EXPERIENCE_DAYS

    mode == 'recall' || record.fetch('layer') == 'knowledge'
  end

  def controls
    {
      null: ->(_query) { [] },
      dump_all: ->(_query) { RECORDS.keys },
      and_prefix: method(:and_prefix),
      oracle: ->(query) { query.fetch('expect') }
    }
  end

  # The pre-fix matcher (REVIEW.md F2) with every eligibility filter correct, so the only
  # thing that can fail it is matching.
  def and_prefix(query)
    terms = query.fetch('text').downcase.split(/[^a-z0-9]+/).reject(&:empty?)
    RECORDS.values.select do |record|
      next false unless eligible?(record, query.fetch('mode'))

      words = record.fetch('statement').downcase.split(/[^a-z0-9]+/)
      matched = terms.all? { |term| words.any? { |word| word.start_with?(term) } }
      matched || (query.fetch('mode') == 'brief' && PROFILE.include?(record['klass']))
    end.map { |record| record.fetch('id') }
  end

  def test_f1_controls_discriminate
    spec_row('F1') do
      verdicts = controls.transform_values { |retriever| score(retriever) }

      assert(verdicts.fetch(:oracle).all?(&:pass?), 'oracle passes every row')
      assert_in_delta(1.0, summary(verdicts.fetch(:oracle)).fetch(:precision))
      assert_null_fails_exactly_the_answerable_rows(verdicts.fetch(:null))
      assert_dump_all_trips_every_filter(verdicts.fetch(:dump_all))
      assert_and_prefix_fails_only_on_matching(verdicts.fetch(:and_prefix))
    end
  end

  def test_b2_the_real_retriever_meets_recall_and_precision_with_zero_violations
    spec_row('B2') do
      result = summary(with_loaded_engine { |retriever| score(retriever) })

      assert_empty result.fetch(:violations), 'scope, sensitivity, lifecycle and layer violations are hard zero'
      assert_equal 0, result.fetch(:over_budget)
      assert_operator result.fetch(:recall), :>=, MIN_RECALL, result.inspect
      assert_operator result.fetch(:precision), :>=, MIN_PRECISION, result.inspect
    end
  end

  def test_b7_stop_words_and_unrelated_text_return_nothing
    spec_row('B7') do
      verdicts = with_loaded_engine { |retriever| score(retriever) }
      empty = verdicts.select { |verdict| verdict.query['empty'] }

      assert_equal 7, empty.length
      assert_empty(empty.reject(&:pass?).map { |verdict| verdict.query.fetch('id') })
    end
  end

  private

  def assert_null_fails_exactly_the_answerable_rows(verdicts)
    assert_equal(verdicts.select(&:answerable?).map { |v| v.query['id'] }, verdicts.reject(&:pass?).map do |v|
      v.query['id']
    end)
  end

  def assert_dump_all_trips_every_filter(verdicts)
    filtered = verdicts.select { |verdict| (FILTER_KINDS - %w[profile]).include?(verdict.kind) }

    refute_empty filtered
    filtered.each { |verdict| refute_empty verdict.violations, verdict.query.fetch('id') }
    assert(verdicts.all?(&:over_budget))
  end

  def assert_and_prefix_fails_only_on_matching(verdicts)
    failed = verdicts.reject(&:pass?)

    refute_empty(failed.select { |verdict| verdict.kind == 'paraphrase' })
    assert_empty(failed.select { |verdict| FILTER_KINDS.include?(verdict.kind) || verdict.kind == 'exact' }
                       .map { |verdict| verdict.query.fetch('id') })
  end

  def with_loaded_engine
    Dir.mktmpdir('tamoz-memory-corpus') do |directory|
      now = Time.at(1_800_000_000)
      engine, adapter = memory_engine_at(directory, clock: -> { now })
      by_memory_id = load_corpus(engine, now).invert
      yield(->(query) { retrieve(engine, query).map { |record| by_memory_id.fetch(record.memory_id) } })
    ensure
      adapter&.close
    end
  end

  def retrieve(engine, query)
    caller = engine.caller(user: CALLER.fetch('user'), project: CALLER.fetch('project'))
    if query.fetch('mode') == 'brief'
      engine.retrieval.brief(caller:, task: query.fetch('text')).records
    else
      engine.retrieval.recall(caller:, query: { terms: [query.fetch('text')] }).records
    end
  end

  def load_corpus(engine, now)
    RECORDS.transform_values do |fixture|
      record = corpus_record(fixture, now)
      engine.repository.append(record:, index: engine.index_for(record), expected_version: nil,
                               sensitive: record.sensitive?)
      if fixture['lifecycle'] == 'superseded'
        engine.lifecycle.supersede(memory_id: record.memory_id, actor: 'corpus', reason: 'replaced')
      end
      record.memory_id
    end
  end

  def corpus_record(fixture, now)
    created = now.to_i - (fixture.fetch('age_days', 0) * DAY)
    experience = fixture.fetch('layer') == 'experience'
    owner = fixture.fetch('user', CALLER.fetch('user'))
    Memory::MemoryRecord.new(
      memory_id: "mem.corpus.#{fixture.fetch('id')}", layer: fixture.fetch('layer').to_sym,
      klass: (fixture['klass'] || 'episode').to_sym, state: :active, statement: fixture.fetch('statement'),
      epistemic_kind: :reported, owner:,
      source_refs: [{ 'identity' => "corpus:#{fixture.fetch('id')}", 'digest' => "d-#{fixture.fetch('id')}" }],
      scopes: memory_scopes(user: owner, project: fixture.fetch('project', CALLER.fetch('project'))),
      sensitivity: fixture.fetch('sensitivity', 'internal').to_sym, valid_from: created,
      valid_until: experience ? created + (EXPERIENCE_DAYS * DAY) : nil,
      transition: { 'actor' => 'corpus', 'reason' => 'corpus fixture' }, created_at_ms: created * 1000
    )
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Minitest/MultipleAssertions, Style/MultilineBlockChain

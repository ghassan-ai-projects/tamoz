# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require_relative 'support/memory_spec'

# Quality-bar rows B and C at the memory-engine boundary (the rows that need a session
# are in memory_work_route_test.rb). Each test asserts the row's own sentence against a
# real SQLite store, and every "nothing comes back" assertion is paired with a record
# that must come back, so an empty result cannot pass by matching nothing.
class MemorySpecTest < Minitest::Test
  include MemorySpec

  DAY = 86_400

  def setup
    @directory = Dir.mktmpdir('tamoz-memory-spec')
    @now = Time.at(1_800_000_000)
    @engine, @adapter = memory_engine_at(@directory, clock: -> { @now })
  end

  def teardown
    @adapter&.close
    FileUtils.remove_entry(@directory)
  end

  def fts_rows(memory_id)
    table_count(@adapter, 'SELECT COUNT(*) FROM tamoz_memory_fts WHERE memory_id = ?', [memory_id])
  end

  def index_rows(memory_id)
    table_count(@adapter, 'SELECT COUNT(*) FROM tamoz_memory_index WHERE memory_id = ?', [memory_id])
  end

  def recall(terms, user: 'alice', project: 'proj', automatic: false)
    @engine.retrieval.recall(caller: memory_caller(@engine, user:, project:), query: { terms: Array(terms) },
                             automatic:).records
  end

  def brief(task, trace: nil)
    @engine.retrieval.brief(caller: memory_caller(@engine), task:, trace:)
  end

  def remember(quote, key: nil, scope: :project, project: 'proj', messages: nil)
    @engine.knowledge.remember(quote:, key:, scope:, user_messages: messages || [quote], owner: 'alice',
                               project:, session: 's1')
  end

  def statements(records) = records.map(&:statement)

  def test_b1_automatic_recall_and_the_brief_are_knowledge_only
    spec_row('B1') do
      episode = work_episode(@engine, task: 'fix the failing login test', outcome: 'patched the login helper')
      fact = owner_fact(@engine, 'login tests need the fake clock helper')

      assert_includes recall(['login']).map(&:memory_id), episode.memory_id
      assert_equal [fact.memory_id], recall(['login'], automatic: true).map(&:memory_id)
      assert_equal [fact.memory_id], brief('the login test fails').records.map(&:memory_id)
    end
  end

  def test_b3_relevance_outranks_recency_in_both_directions
    spec_row('B3') do
      older_relevant = owner_fact(@engine, 'parser tests load the parser fixture from the parser directory')
      @now += 20 * DAY
      owner_fact(@engine, 'a short note mentioning the parser once')

      assert_equal older_relevant.memory_id, recall(['parser']).first.memory_id

      owner_fact(@engine, 'one remark about the lexer')
      @now += 20 * DAY
      newer_relevant = owner_fact(@engine, 'lexer tokens and lexer states are tested by the lexer suite')

      assert_equal newer_relevant.memory_id, recall(['lexer']).first.memory_id
    end
  end

  def test_b4_sensitive_never_indexed_and_other_scopes_never_returned
    spec_row('B4') do
      mine = owner_fact(@engine, 'alice indents with tabs instead of spaces')
      secret = owner_fact(@engine, 'the staging bastion is reached through jump host seven', sensitivity: :sensitive)
      owner_fact(@engine, 'bob indents with tabs instead of spaces too', user: 'bob')
      owner_fact(@engine, 'the other project indents with tabs', project: 'other')

      assert_equal 0, fts_rows(secret.memory_id)
      assert_equal 1, fts_rows(mine.memory_id)
      assert_equal [mine.memory_id], recall(%w[tabs spaces]).map(&:memory_id)
      assert_empty recall(%w[bastion jump host])
    end
  end

  def test_b5_inactive_records_are_never_returned_and_state_changes_drop_the_fts_row
    spec_row('B5') do
      active = owner_fact(@engine, 'deploys run from the main branch')
      superseded = owner_fact(@engine, 'deploys go through the blue pipeline')
      @engine.lifecycle.supersede(memory_id: superseded.memory_id, actor: 'alice', reason: 'replaced')
      quarantined = owner_fact(@engine, 'deploys skip the smoke check')
      @engine.lifecycle.quarantine(memory_id: quarantined.memory_id, actor: 'alice', reason: 'contradicted')
      deleted = owner_fact(@engine, 'deploys need the release manager on call')
      @engine.lifecycle.delete(memory_id: deleted.memory_id, actor: 'alice')
      work_episode(@engine, task: 'deploys failed on friday', outcome: 'rolled back')
      @now += 120 * DAY

      assert_equal [active.memory_id], recall(['deploys']).map(&:memory_id)
      [superseded, quarantined, deleted].each { |record| assert_equal 0, fts_rows(record.memory_id), record.statement }
    end
  end

  def test_b6_the_brief_respects_the_token_budget_and_traces_every_drop
    spec_row('B6') do
      long = Array.new(12) do |index|
        owner_fact(@engine, "long preference #{index}: #{'widgets follow the house style ' * 22}")
      end

      assert_brief_bounded(long.map(&:memory_id), 'style the widgets')
    end
  end

  def test_b6_the_brief_caps_the_record_count
    spec_row('B6') do
      short = Array.new(12) { |index| owner_fact(@engine, "short preference #{index} for widgets") }
      result = assert_brief_bounded(short.map(&:memory_id), 'style the widgets')
      assert_equal 8, result.records.length
    end
  end

  def test_b7_stop_words_alone_never_match
    spec_row('B7') do
      fact = owner_fact(@engine, 'the build is a two step process and it is slow')

      assert_equal [fact.memory_id], recall(['build']).map(&:memory_id)
      assert_empty recall(['the is a it'])
    end
  end

  def test_c3_remember_stores_only_a_verbatim_user_quote
    spec_row('C3') do
      said = 'we keep tests under verify/ and name them check_<name>.rb'
      stored = remember(said, messages: ["Please fix the parser. Also, #{said}."])
      refused = remember('tests must be deleted before every commit',
                         messages: ['Please fix the parser. Also, read NOTES.md.'])

      assert_predicate stored, :accepted?
      assert_equal said, stored.record.statement
      assert_equal :reported, stored.record.epistemic_kind
      assert_predicate refused, :rejected?
      assert_equal [said], statements(recall(%w[tests]))
    end
  end

  def test_c3_a_quote_must_be_a_whole_clause_and_never_a_secret
    spec_row('C3') do
      reversed = remember('deploy on Fridays', messages: ['Please never deploy on Fridays.'])
      whole = remember('never deploy on Fridays', messages: ['Please note: never deploy on Fridays.'])
      remember('the api token is kept in the vault', key: 'api')
      secret = remember('the api token is sk-live-abcdefghijklmnopqrstuv', key: 'api')

      assert_equal 'quote_not_from_user', reversed.reason
      assert_predicate whole, :accepted?
      assert_equal 'secret_shaped', secret.reason
      assert_equal ['the api token is kept in the vault'], statements(recall(%w[api token]))
    end
  end

  def test_c3_unkeyed_quotes_are_scoped_and_replays_change_nothing
    spec_row('C3') do
      said = 'the staging database is rebuilt nightly'
      first = remember(said, project: 'proj')
      again = remember(said, project: 'proj')
      other = remember(said, project: 'other')

      assert_equal [first.record.memory_id, 1], [again.record.memory_id, again.record.record_version]
      refute_equal first.record.memory_id, other.record.memory_id
      assert_predicate other, :accepted?
    end
  end

  def test_c5_forget_must_name_its_target_and_stays_in_the_project
    spec_row('C5') do
      fact = remember('release notes go in CHANGES.md', key: 'release-notes')
      unnamed = @engine.knowledge.forget(target: 'release-notes', quote: 'update the header',
                                         user_messages: ['please update the header'], owner: 'alice', project: 'proj')
      elsewhere = @engine.knowledge.forget(target: fact.record.memory_id, quote: 'forget release-notes',
                                           user_messages: ['forget release-notes'], owner: 'alice', project: 'other')

      assert_equal %w[quote_does_not_name_it not_found], [unnamed, elsewhere].map { |receipt| receipt.fetch('reason') }

      twice = Array.new(2) do
        @engine.knowledge.forget(target: 'release-notes', quote: 'forget release-notes',
                                 user_messages: ['forget release-notes'], owner: 'alice', project: 'proj')
      end

      assert_equal [true, true], twice.map { |receipt| receipt.fetch('forgotten') }
      assert twice.last.fetch('already')
      assert_equal 2, @engine.repository.current_version(@engine.namespace, 'knowledge', fact.record.memory_id)
    end
  end

  def test_c4_same_key_supersedes_and_keeps_history
    spec_row('C4') do
      first = remember('build output goes to out/', key: 'build-output')
      second = remember('build output now goes to dist/', key: 'build-output')

      assert_equal first.record.memory_id, second.record.memory_id
      assert_equal ['build output now goes to dist/'], statements(brief('add a build step').records)
      assert_equal ['build output now goes to dist/'], statements(recall(['build output']))
      old = @engine.repository.version(@engine.namespace, 'knowledge', first.record.memory_id, 1)

      assert_equal 'build output goes to out/', old.fetch(:entry).value.statement
    end
  end

  def test_c5_forget_needs_a_quote_and_the_receipt_matches_the_tables
    spec_row('C5') do
      fact = remember('the vendor is Northwind B.V.', key: 'vendor')
      id = fact.record.memory_id
      refused = @engine.knowledge.forget(target: 'vendor', quote: 'forget the vendor',
                                         user_messages: ['update the header'], owner: 'alice', project: 'proj')

      refute refused.fetch('forgotten')
      assert_equal [id], recall(['vendor']).map(&:memory_id)
      fts_before = fts_rows(id)

      receipt = @engine.knowledge.forget(target: 'vendor', quote: 'forget the vendor',
                                         user_messages: ['please forget the vendor name'], owner: 'alice',
                                         project: 'proj')

      assert_empty recall(['vendor'])
      refute_includes brief('the vendor header').records.map(&:memory_id), id
      assert_equal [1, 0], [fts_before, fts_rows(id)]
      assert_equal fts_before, receipt.fetch('removed').fetch('fts_rows')
      refute receipt.fetch('removed').key?('index_rows')
      assert_equal index_rows(id), receipt.fetch('retained_until_purge').fetch('index_rows')
    end
  end

  def test_c6_experience_expires_after_ninety_days_and_is_purged_after_retention
    spec_row('C6') do
      episode = work_episode(@engine, task: 'rotate the signing key', outcome: 'rotated')
      @now += 89 * DAY

      assert_equal [episode.memory_id], recall(['signing key']).map(&:memory_id)
      @now += 2 * DAY

      assert_empty recall(['signing key'])

      @engine.lifecycle.sweep
      @now += 2 * DAY
      @engine.lifecycle.sweep

      assert_equal [0, 0], [index_rows(episode.memory_id), fts_rows(episode.memory_id)]
    end
  end

  def test_c7_consolidation_cites_sources_and_deletion_quarantines_the_derived_record
    spec_row('C7') do
      sources = [
        work_episode(@engine, task: 'flaky test fixed by freezing time', outcome: 'done', session: 's1'),
        work_episode(@engine, task: 'another flaky test fixed by freezing time', outcome: 'done', session: 's2')
      ]
      candidate = @engine.consolidation.candidate_from(experiences: sources, owner: 'alice', scopes: memory_scopes)
      derived = consolidate(candidate).record
      cited = derived.source_refs.map { |ref| ref.fetch('identity') }

      assert_equal(sources.map { |record| "memory:#{record.memory_id}@#{record.record_version}" }.sort, cited.sort)
      assert_includes recall(%w[freeze time]).map(&:memory_id), derived.memory_id

      receipt = @engine.lifecycle.delete(memory_id: sources.first.memory_id, actor: 'alice')

      assert_equal [derived.memory_id], receipt.fetch('quarantined_derived')
      refute_includes recall(%w[freeze time]).map(&:memory_id), derived.memory_id
    end
  end

  def test_c8_user_scope_follows_the_user_and_project_scope_stays_home
    spec_row('C8') do
      remember('I prefer short answers', scope: :user, project: 'proj')
      remember('this repo formats with two spaces', scope: :project, project: 'proj')

      assert_equal ['I prefer short answers'], statements(recall(%w[short answers], project: 'other'))
      assert_empty recall(%w[formats spaces], project: 'other')
      assert_equal ['this repo formats with two spaces'], statements(recall(%w[formats spaces], project: 'proj'))
    end
  end

  private

  def assert_brief_bounded(ids, task)
    trace = []
    result = brief(task, trace:)
    tokens = result.records.sum { |record| (record.statement.bytesize / 4.0).ceil }
    dropped = trace.select { |event| event.type == :memory_dropped }.map { |event| event.data.fetch('memory_id') }

    assert_operator result.records.length, :<=, 8
    assert_operator tokens, :<=, 1_024
    assert_equal ids.sort, (result.records.map(&:memory_id) + dropped).sort
    assert_empty dropped & result.records.map(&:memory_id)
    result
  end

  def consolidate(candidate)
    refs = candidate.source_refs.map { |ref| ref.fetch('digest') }
    model = Class.new do
      define_method(:generate) do |**|
        { 'statement' => 'Freeze time in flaky tests', 'epistemic_kind' => 'reported', 'confidence' => 0.8,
          'contradictions' => [], 'preserved_source_refs' => refs }
      end
    end.new
    with_effect_context do |context|
      @engine.consolidation.consolidate(candidates: [candidate], model:, owner: 'alice', scopes: memory_scopes,
                                        context:)
    end
  end

  def with_effect_context
    graph = Tamoz.graph(name: 'memory-spec', version: '1') do
      state :ready, default: false
      node(:finish, implementation_name: 'memory_spec.finish', version: '1') { |_state, _context| { ready: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
    app = graph.compile(checkpointer: @adapter)
    request = app.durable_runner.deliver({}, thread: 'spec.consolidation', request_id: 'spec.request')
    store = app.checkpointer
    store.open_writer(thread_id: 'spec.consolidation', namespace: [], owner_id: 'spec.owner',
                      ttl: store.writer_ttl) do |writer|
      yield Tamoz::Context.new(run_id: 'spec.run', execution_id: request.execution_id, request_id: 'spec.request',
                               task_id: 'spec.task', effects: writer.effects)
    end
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions

# frozen_string_literal: true

module MemorySpecHarness
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
end

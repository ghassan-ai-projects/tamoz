# frozen_string_literal: true

require_relative '../../../test/test_helper'
require_relative '../../../test/support/memory_spec'
require 'benchmark'
class B; include MemorySpec; end
SPEC = B.new
M = Tamoz::Agent::Memory
QUERY = { terms: ['login retry queue'] }.freeze
BRIEF_TASK = 'fix the parser cache'
WORDS = %w[deploy parser login cache invoice vendor build release slug queue retry index report token schema widget
           config].freeze
PLAN_SQL = 'EXPLAIN QUERY PLAN SELECT i.memory_id FROM tamoz_memory_index i JOIN tamoz_store_heads h ' \
           "ON h.namespace = i.store_namespace AND h.key = i.layer || '/' || i.memory_id " \
           'AND h.current_version = i.record_version AND h.deleted = 0 JOIN tamoz_memory_fts ' \
           'ON tamoz_memory_fts.store_namespace = i.store_namespace ' \
           'AND tamoz_memory_fts.memory_id = i.memory_id ' \
           "WHERE i.store_namespace = 'x' AND tamoz_memory_fts MATCH 'login' " \
           'ORDER BY bm25(tamoz_memory_fts)'

def klass_for(layer, index)
  return :episode if layer == :experience

  (index % 5).zero? ? :preference : :procedure
end

def record_for(index, layer, now)
  statement = "#{layer} note #{index}: #{WORDS.sample(4, random: Random.new(index)).join(' ')} " \
              "handled in step #{index % 97}"
  M::MemoryRecord.new(memory_id: "mem.b.#{layer}.#{index}", layer:, klass: klass_for(layer, index), state: :active,
                      statement:, epistemic_kind: :reported, owner: 'alice',
                      source_refs: [{ 'identity' => "b:#{index}", 'digest' => "d#{index}" }],
                      scopes: SPEC.memory_scopes, sensitivity: :internal, valid_from: now.to_i,
                      transition: { 'actor' => 'b', 'reason' => 'bench' }, created_at_ms: now.to_i * 1000)
end

def append_records(engine, now, layer, count)
  count.times do |index|
    record = record_for(index, layer, now)
    engine.repository.append(record:, index: engine.index_for(record), expected_version: nil, sensitive: false)
  end
end

def report_load(engine, now, knowledge, experience)
  seconds = Benchmark.realtime do
    append_records(engine, now, :knowledge, knowledge)
    append_records(engine, now, :experience, experience)
  end
  printf("load %<kn>d knowledge + %<ex>d experience: %<t>.1fs (%<ms>.2f ms/record)\n",
         kn: knowledge, ex: experience, t: seconds, ms: seconds * 1000 / (knowledge + experience))
end

def report_search(engine, caller)
  rows = nil
  ts_search = Benchmark.realtime { rows = engine.repository.search(caller:, query: QUERY, limit: 200).candidates }
  ts_get = Benchmark.realtime do
    rows.each do |r|
      engine.store.get(engine.namespace, "#{r['layer']}/#{r['memory_id']}")
    end
  end
  printf("search %<search>.0f ms (%<rows>d rows) | 200 gets %<gets>.0f ms\n",
         search: ts_search * 1000, rows: rows.length, gets: ts_get * 1000)
end

def report_plan(dir)
  SQLite3::Database.new(File.join(dir, 'memory.sqlite3')).execute(PLAN_SQL).each { |row| puts "  plan: #{row.last}" }
end

def average_ms(runs, &)
  Benchmark.realtime { runs.times(&) } / runs * 1000
end

def db_megabytes(dir) = File.size(File.join(dir, 'memory.sqlite3')) / 1e6

def report_latency(engine, caller, dir)
  3.times { engine.retrieval.brief(caller:, task: BRIEF_TASK) }
  brief = average_ms(10) { engine.retrieval.brief(caller:, task: BRIEF_TASK) }
  recall = average_ms(10) { engine.retrieval.recall(caller:, query: QUERY) }
  delete = average_ms(5) { |i| engine.lifecycle.delete(memory_id: "mem.b.knowledge.#{i + 1}") }
  sweep = Benchmark.realtime { engine.lifecycle.sweep } * 1000
  printf("brief %<b>.0f ms | recall %<r>.0f ms | delete %<d>.0f ms | sweep %<s>.0f ms | db %<m>.1f MB\n",
         b: brief, r: recall, d: delete, s: sweep, m: db_megabytes(dir))
end

Dir.mktmpdir do |d|
  now = Time.at(1_800_000_000)
  e, a = SPEC.memory_engine_at(d, clock: -> { now })
  report_load(e, now, 2_000, 8_000)
  c = e.caller(user: 'alice', project: 'proj')
  report_search(e, c)
  report_plan(d)
  report_latency(e, c, d)
  a.close
end

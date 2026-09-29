require_relative "../../../test/test_helper"
require_relative "../../../test/support/memory_spec"
require "benchmark"
class B; include MemorySpec; end
b = B.new; M = Tamoz::Agent::Memory
WORDS = %w[deploy parser login cache invoice vendor build release slug queue retry index report token schema widget config]
Dir.mktmpdir do |d|
  now = Time.at(1_800_000_000)
  e, a = b.memory_engine_at(d, clock: -> { now })
  add = lambda do |i, layer, klass|
    st = "#{layer} note #{i}: #{WORDS.sample(4, random: Random.new(i)).join(' ')} handled in step #{i % 97}"
    r = M::MemoryRecord.new(memory_id: "mem.b.#{layer}.#{i}", layer:, klass:, state: :active, statement: st, epistemic_kind: :reported,
      owner: 'alice', source_refs: [{ 'identity' => "b:#{i}", 'digest' => "d#{i}" }], scopes: b.memory_scopes,
      sensitivity: :internal, valid_from: now.to_i, transition: { 'actor' => 'b', 'reason' => 'bench' }, created_at_ms: now.to_i * 1000)
    e.repository.append(record: r, index: e.index_for(r), expected_version: nil, sensitive: false)
  end
  [[2_000, 8_000]].each do |kn, ex|
    t = Benchmark.realtime { kn.times { |i| add.(i, :knowledge, i % 5 == 0 ? :preference : :procedure) }; ex.times { |i| add.(i, :experience, :episode) } }
    printf("load %d knowledge + %d experience: %.1fs (%.2f ms/record)\n", kn, ex, t, t * 1000 / (kn + ex))
    c = e.caller(user: 'alice', project: 'proj')
    q = { terms: ['login retry queue'] }
    ts_search = Benchmark.realtime { @rows = e.repository.search(caller: c, query: q, limit: 200).candidates }
    ts_get = Benchmark.realtime { @rows.each { |r| e.store.get(e.namespace, "#{r['layer']}/#{r['memory_id']}") } }
    printf("search %.0f ms (%d rows) | 200 gets %.0f ms
", ts_search * 1000, @rows.length, ts_get * 1000)
    db = SQLite3::Database.new(File.join(d, 'memory.sqlite3'))
    plan = db.execute("EXPLAIN QUERY PLAN SELECT i.memory_id FROM tamoz_memory_index i JOIN tamoz_store_heads h ON h.namespace = i.store_namespace AND h.key = i.layer || '/' || i.memory_id AND h.current_version = i.record_version AND h.deleted = 0 JOIN tamoz_memory_fts ON tamoz_memory_fts.store_namespace = i.store_namespace AND tamoz_memory_fts.memory_id = i.memory_id WHERE i.store_namespace = 'x' AND tamoz_memory_fts MATCH 'login' ORDER BY bm25(tamoz_memory_fts)")
    plan.each { |row| puts "  plan: #{row.last}" }
    3.times { e.retrieval.brief(caller: c, task: 'fix the parser cache') }
    tb = Benchmark.realtime { 10.times { e.retrieval.brief(caller: c, task: 'fix the parser cache') } } / 10
    tr = Benchmark.realtime { 10.times { e.retrieval.recall(caller: c, query: { terms: ['login retry queue'] }) } } / 10
    td = Benchmark.realtime { 5.times { |i| e.lifecycle.delete(memory_id: "mem.b.knowledge.#{i + 1}") } } / 5
    ts = Benchmark.realtime { e.lifecycle.sweep }
    printf("brief %.0f ms | recall %.0f ms | delete %.0f ms | sweep %.0f ms | db %.1f MB\n", tb * 1000, tr * 1000, td * 1000, ts * 1000, File.size(File.join(d, 'memory.sqlite3')) / 1e6)
  end
  a.close
end

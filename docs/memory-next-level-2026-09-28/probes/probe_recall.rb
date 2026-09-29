require_relative "../../../test/test_helper"
M = Tamoz::Agent::Memory
Dir.mktmpdir do |dir|
  adapter = Tamoz::SQLite::Adapter.new(path: File.join(dir, "t.sqlite3"), state_codec: M::Surface.codec)
  eng = M::Engine.new(tenant: "acme", adapter:)
  ep = {session_id: "s1", task: "fix the failing login test", plan_digest: "sha256:x",
        scopes: {"tenant"=>"acme","user"=>"session","project"=>"session","session"=>"s1"},
        observed_outcome: {"outcome"=>"patched auth_helper.rb; login test passes"}}
  r = eng.admission.admit_episode(episode: ep, owner: "session")
  puts "admitted=#{r.accepted?} layer=#{r.record.layer} statement=#{r.record.statement.inspect}"
  caller = eng.caller(user: "session", project: "session")
  [["fix the failing login test"], ["the login test is failing again"], ["login"], ["login test"]].each do |terms|
    rec = eng.retrieval.recall(caller:, query: {terms:}, automatic: true)
    puts "automatic terms=#{terms.first.inspect} -> #{rec.records.map { |x| [x.layer, x.memory_id[0,12]] }.inspect}"
  end
  adapter.close
end

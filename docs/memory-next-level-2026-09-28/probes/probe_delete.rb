require_relative "../../../test/test_helper"
M = Tamoz::Agent::Memory
Dir.mktmpdir do |dir|
  adapter = Tamoz::SQLite::Adapter.new(path: File.join(dir, "t.sqlite3"), state_codec: M::Surface.codec)
  eng = M::Engine.new(tenant: "acme", adapter:)
  r = eng.admission.admit_owner_request(statement: "Prefer rspec over minitest in project X", owner: "u1", authority: "owner",
        scopes: {"tenant"=>"acme","user"=>"u1","project"=>"x"})
  puts "owner fast path accepted=#{r.accepted?}"
  receipt = eng.lifecycle.delete(memory_id: r.record.memory_id, actor: "u1")
  puts receipt.inspect
  adapter.close
end

# frozen_string_literal: true

# rubocop:disable Metrics/ParameterLists

# The memory quality bar (docs/memory-next-level-2026-09-28/QUALITY_BAR.md) as an
# executable specification. A row listed in MET must hold; any other row asserts its
# target and, while Tamoz falls short, reports a PENDING gap instead of a green that
# would encode the wrong behaviour. Moving a row into MET is the only way it becomes
# a hard failure, so a met row can never silently regress into a skip.
module MemorySpec
  MET = %w[E5 F1 B1 B2 B3 B4 B5 B6 B7 C1 C2 C3 C3.route C4 C5 C6 C7 C8 D1 D2 D3 E1 E2 E3 E4].freeze
  PENDING = Hash.new { |hash, key| hash[key] = [] }

  Memory = Tamoz::Agent::Memory

  Minitest.after_run do
    next if PENDING.empty?

    PENDING.sort.each { |row, details| warn "memory spec PENDING #{row}: #{details.uniq.join(' | ')}" }
  end

  # A named test protection codec: sensitive Store values refuse to persist without one.
  class XorProtection
    def name = 'test.memory_spec.xor'
    def encrypt(bytes, **) = bytes.b.bytes.map { |byte| byte ^ 0x5A }.pack('C*')
    def decrypt(bytes, **) = bytes.bytes.map { |byte| byte ^ 0x5A }.pack('C*')
  end

  # What a missing or wrong target looks like at the parent: an assertion, a missing
  # API, or a Tamoz error raised out of the behaviour. Any other exception is a bug in
  # the test and propagates.
  GAP_ERRORS = [Minitest::Assertion, NoMethodError, ArgumentError, Tamoz::Error].freeze

  def spec_row(row)
    yield
    flunk "#{row} now holds: add it to MemorySpec::MET" unless MET.include?(row)
  rescue Minitest::Skip
    raise
  rescue *GAP_ERRORS => e
    raise if MET.include?(row) || e.message.include?('add it to MemorySpec::MET')

    detail = e.message.lines.first.to_s.strip[0, 160]
    PENDING[row] << detail
    skip "PENDING GAP #{row}: #{e.class}: #{detail}"
  end

  def table_count(adapter, sql, binds)
    count = nil
    adapter.store.open_transaction(label: 'spec.count') { |tx| count = tx.scalar('spec.count', sql, binds) }
    count
  end

  def memory_engine_at(directory, clock:, protection: XorProtection.new, file: 'memory.sqlite3')
    adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(directory, file),
      state_codec: Memory::Surface.codec,
      store_protection: protection,
      limits: Tamoz::SQLite::Limits.new(deletion_retention: 86_400.0)
    )
    [Memory::Engine.new(tenant: 'acme', adapter:, protection:, clock:), adapter]
  end

  def memory_scopes(user: 'alice', project: 'proj', session: 's1')
    { 'tenant' => 'acme', 'user' => user, 'project' => project, 'session' => session }
  end

  def memory_caller(engine, user: 'alice', project: 'proj')
    engine.caller(user:, project:)
  end

  def owner_fact(engine, statement, user: 'alice', project: 'proj', klass: :preference, sensitivity: :internal)
    result = engine.admission.admit_owner_request(
      statement:, owner: user, authority: 'owner', klass:, sensitivity:,
      scopes: memory_scopes(user:, project:)
    )
    raise "owner fact not admitted: #{result.reason}" unless result.accepted?

    result.record
  end

  def work_episode(engine, task:, outcome:, user: 'alice', project: 'proj', session: 's1', completed_at: nil)
    result = engine.admission.admit_episode(
      episode: {
        session_id: session, task:, plan_digest: "sha256:#{task}",
        completed_at: completed_at || engine.clock.call.to_i,
        scopes: memory_scopes(user:, project:, session:),
        observed_outcome: { 'outcome' => outcome }
      },
      owner: user
    )
    raise "episode not admitted: #{result.reason}" unless result.accepted?

    result.record
  end
end
# rubocop:enable Metrics/ParameterLists

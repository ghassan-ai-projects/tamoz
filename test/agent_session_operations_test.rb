# frozen_string_literal: true

require_relative "test_helper"

# P6-F: operational durability of a real durable agent session.
class AgentSessionOperationsTest < Minitest::Test
  class ScriptedModel
    attr_reader :calls

    def initialize(digest)
      @digest = digest
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      phase = begin
        JSON.parse(prompt)["phase"]
      rescue StandardError
        nil
      end || "verify"
      @calls << "#{stage}:#{phase}"
      case stage
      when :plan then JSON.generate(phase == "discovery" ? discovery : action)
      when :review then JSON.generate("decision" => "accept", "issues" => [], "rationale" => "sound")
      else
        JSON.generate("answer" => "value is 2", "satisfied" => true, "evidence" => ["app.rb"])
      end
    end

    private

    def discovery
      {
        "goal" => "read the current value",
        "done_when" => ["app.rb has been read"],
        "steps" => [
          {
            "id" => "look",
            "purpose" => "read the file",
            "tool" => "read_file",
            "arguments" => {"path" => "app.rb"},
            "verification" => "the digest is present"
          }
        ]
      }
    end

    def action
      {
        "goal" => "set value to 2",
        "done_when" => ["app.rb contains value = 2 and the check passes"],
        "steps" => [
          {
            "id" => "edit",
            "purpose" => "apply the exact replacement",
            "tool" => "apply_patch",
            "arguments" => {
              "path" => "app.rb",
              "expected_sha256" => @digest,
              "before" => "value = 1",
              "after" => "value = 2"
            },
            "verification" => "the receipt reports the new digest"
          },
          {
            "id" => "check",
            "purpose" => "run the configured check",
            "tool" => "run_check",
            "arguments" => {"name" => "answer"},
            "verification" => "the check exits zero"
          }
        ]
      }
    end
  end

  def test_a_paused_session_survives_backup_and_restore_and_resumes_from_the_copy
    with_paused_session do |context|
      destination = File.join(context.fetch(:directory), "backup.sqlite3")
      report = context.fetch(:adapter).backup(destination)

      assert_operator report.bytes, :>, 0
      assert_equal 0, File.stat(destination).mode & 0o077

      context.fetch(:adapter).close
      restored = Tamoz::SQLite::Adapter.new(path: destination)
      session = build_session(context, restored)
      view = session.view(thread: thread_id)

      assert_equal 1, view.interrupts.length
      outcome = drive_to_completion(session, view)

      assert_equal :completed, outcome.status
      assert_equal "value = 2\n", File.read(File.join(context.fetch(:workspace), "app.rb"))
      assert restored.integrity_check.fetch("ok")
    ensure
      restored&.close
    end
  end

  def test_a_corrupted_checkpoint_payload_is_reported_and_never_silently_skipped
    with_paused_session do |context|
      adapter = context.fetch(:adapter)
      corrupt_active_checkpoint(adapter)

      error = assert_raises(Tamoz::CheckpointCorruptionError) do
        build_session(context, adapter).view(thread: thread_id)
      end

      assert_match(/digest is invalid/, error.message)
    end
  end

  def test_retention_pruning_never_removes_the_active_tip_of_a_paused_session
    with_paused_session do |context|
      adapter = context.fetch(:adapter)
      session = build_session(context, adapter)
      before = session.view(thread: thread_id)

      report = session.app.checkpointer.prune(thread_id: thread_id, keep: 1)
      after = build_session(context, adapter).view(thread: thread_id)

      assert_operator report.deleted_count, :>=, 0
      assert_equal before.sequence, after.sequence
      assert_equal 1, after.interrupts.length

      outcome = drive_to_completion(build_session(context, adapter), after)
      assert_equal :completed, outcome.status
      assert adapter.integrity_check.fetch("ok")
    end
  end

  def test_thread_deletion_requires_the_current_tip_and_then_blocks_further_work
    with_paused_session do |context|
      adapter = context.fetch(:adapter)
      session = build_session(context, adapter)
      view = session.view(thread: thread_id)
      authorization = Tamoz::SQLite::DeletionAuthorization.new(
        actor: "test.operator",
        reason: "operational durability test"
      )

      # Deletion is compare-protected: it must present the current tip. Once
      # tombstoned, the thread accepts no further work. This does not exercise the
      # unresolved-effect guard, which needs a prepared/running/unknown effect and is
      # covered by test/sqlite_deletion_test.rb.
      assert_raises(Tamoz::CheckpointConflictError) do
        adapter.tombstone_thread(
          thread_id:,
          expected_tips: {[] => "not-the-tip"},
          authorization:
        )
      end

      report = adapter.tombstone_thread(
        thread_id:,
        expected_tips: {[] => view.checkpoint_id},
        authorization:
      )
      assert_equal :active, report.status
      assert_raises(Tamoz::CheckpointConflictError) do
        session.resume(
          {view.interrupts.first.task_id => {0 => true}},
          thread: thread_id,
          request_id: "blocked"
        )
      end
    end
  end

  def test_two_concurrent_owners_cannot_both_advance_the_same_session
    with_paused_session do |context|
      store = build_session(context, context.fetch(:adapter)).app.checkpointer
      store.open_writer(
        thread_id:,
        namespace: [],
        owner_id: "owner.first",
        ttl: store.writer_ttl
      ) do |_writer|
        assert_raises(Tamoz::CheckpointConflictError) do
          store.open_writer(
            thread_id:,
            namespace: [],
            owner_id: "owner.second",
            ttl: store.writer_ttl
          ) { |_other| flunk("two owners advanced one namespace") }
        end
      end
    end
  end

  def test_repeated_session_cycles_do_not_leak_file_descriptors
    Dir.mktmpdir("tamoz-session-leak") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      baseline = nil
      8.times do |index|
        File.write(File.join(workspace, "app.rb"), "value = 1\n")
        adapter = Tamoz::SQLite::Adapter.new(
          path: File.join(directory, "session-#{index}.sqlite3"),
          limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2)
        )
        context = {
          workspace: File.realpath(workspace),
          digest: Digest::SHA256.hexdigest("value = 1\n")
        }
        session = build_session(context, adapter)
        outcome = session.start(
          "set value to 2",
          thread: "leak.#{index}",
          request_id: "r0"
        )
        outcome = drive_to_completion(session, session.view(thread: "leak.#{index}"))
        assert_equal :completed, outcome.status
        adapter.close
        baseline = open_descriptors if index == 1
      end

      growth = open_descriptors - baseline
      assert_operator growth, :<=, 8,
                      "file descriptors grew by #{growth} across eight session cycles"
    end
  end

  private

  def thread_id = "session.ops"

  def open_descriptors
    Dir.children("/dev/fd").length
  rescue SystemCallError
    ObjectSpace.each_object(IO).count { |io| !io.closed? }
  end

  def with_paused_session
    Dir.mktmpdir("tamoz-session-ops") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2)
      )
      context = {
        directory:,
        workspace: File.realpath(workspace),
        digest: Digest::SHA256.hexdigest("value = 1\n"),
        adapter:
      }
      session = build_session(context, adapter)
      outcome = session.start("set value to 2", thread: thread_id, request_id: "r0")
      assert_equal :paused, outcome.status

      yield context
    ensure
      adapter&.close
    end
  end

  def build_session(context, adapter)
    Tamoz::Agent::Session.new(
      model: ScriptedModel.new(context.fetch(:digest)),
      toolbox: Tamoz::Agent::Toolbox.new(
        root: context.fetch(:workspace),
        allow_changes: true,
        checks: {
          "answer" => [
            RbConfig.ruby,
            "-e",
            %q{abort("wrong") unless File.read("app.rb") == "value = 2\n"}
          ]
        }
      ),
      checkpointer: adapter
    )
  end

  def drive_to_completion(session, view, limit: 8)
    outcome = nil
    index = 0
    while index < limit
      break if view.interrupts.empty?

      index += 1
      outcome = session.resume(
        {view.interrupts.first.task_id => {0 => true}},
        thread: view.thread_id,
        request_id: "resume.#{index}.#{SecureRandom.hex(4)}"
      )
      view = session.view(thread: view.thread_id)
    end
    outcome
  end

  def corrupt_active_checkpoint(adapter)
    encoded = Tamoz::SQLite.const_get(:Wire, false).namespace([])
    row = adapter.__send__(:read, operation: "test.checkpoint") do |tx|
      tx.first(
        "test.checkpoint",
        <<~SQL,
          SELECT c.id, c.payload
          FROM tamoz_namespaces n
          JOIN tamoz_checkpoints c ON c.id = n.active_checkpoint_id
          WHERE n.thread_id = ? AND n.namespace = ?
        SQL
        [thread_id, encoded]
      )
    end
    payload = row.fetch(1)
    corrupted = payload.sub("value = 1", "value = X")
    refute_equal payload, corrupted
    adapter.__send__(:transaction, operation: "test.corrupt") do |tx|
      tx.execute(
        "test.corrupt",
        "UPDATE tamoz_checkpoints SET payload = ? WHERE id = ?",
        [Tamoz::SQLite.const_get(:Wire, false).blob(corrupted), row.fetch(0)]
      )
    end
  end
end

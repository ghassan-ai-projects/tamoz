# frozen_string_literal: true

require_relative "test_helper"

class SQLiteCrashRecoveryTest < Minitest::Test
  LEASE_CHILD = <<~'RUBY'
    require "tamoz/sqlite"
    adapter = Tamoz::SQLite::Adapter.new(
      path: ENV.fetch("TAMOZ_DB_PATH"),
      limits: Tamoz::SQLite::Limits.new(lease_ttl: 0.5)
    )
    STDIN.read(1)
    begin
      store = Tamoz.graph(name: "lease-race", version: "1") {
        state :value, default: 0
        node(:noop, implementation_name: "lease.noop", version: "1") { {} }
        edge Tamoz::START, :noop
        edge :noop, Tamoz::END
      }.compile(checkpointer: adapter).checkpointer
      store.open_writer(
        thread_id: "thread.race",
        namespace: [],
        owner_id: ENV.fetch("TAMOZ_OWNER"),
        ttl: 0.5
      ) do |writer|
        STDOUT.write("acquired:#{writer.fence}")
        STDOUT.flush
        sleep 0.2
      end
    rescue Tamoz::CheckpointConflictError
      STDOUT.write("conflict")
    ensure
      adapter.close
    end
  RUBY
  CHILD = <<~'RUBY'
    require "tamoz/sqlite"
    point = ENV.fetch("TAMOZ_KILL_POINT").to_sym
    operation = ENV.fetch("TAMOZ_KILL_OPERATION", "checkpoint.commit")
    fired = false
    fault = lambda do |candidate, metadata|
      next if fired
      next unless candidate == point
      next unless metadata.fetch("operation") == operation

      fired = true
      Process.kill("KILL", Process.pid)
    end
    definition = Tamoz.graph(name: "crash-recovery", version: "1") do
      state :input, default: ""
      state :seen, reduce: :append, default: []
      node(:record, implementation_name: "crash.record", version: "1") do |state, _context|
        if ENV["TAMOZ_MARKER_PATH"]
          File.open(ENV.fetch("TAMOZ_MARKER_PATH"), "ab") { |file| file.write("x\n") }
        end
        {seen: [state.fetch(:input)]}
      end
      edge Tamoz::START, :record
      edge :record, Tamoz::END
    end
    adapter = Tamoz::SQLite::Adapter.new(
      path: ENV.fetch("TAMOZ_DB_PATH"),
      limits: Tamoz::SQLite::Limits.new(lease_ttl: 0.1),
      fault_injector: fault
    )
    definition.compile(checkpointer: adapter).durable_runner.deliver(
      {"input" => "once"},
      thread: "thread.crash",
      request_id: "request.crash"
    )
    exit 70
  RUBY

  def test_process_kill_before_and_after_checkpoint_commit_recovers_one_execution
    %w[before_commit after_commit].each do |point|
      Dir.mktmpdir("tamoz-kill-#{point}") do |directory|
        path = File.join(directory, "tamoz.sqlite3")
        status = run_killed_child(path, point)
        assert status.signaled?, "child unexpectedly exited #{status.inspect}"
        assert_equal Signal.list.fetch("KILL"), status.termsig

        sleep 0.12
        adapter = Tamoz::SQLite::Adapter.new(
          path:,
          limits: Tamoz::SQLite::Limits.new(lease_ttl: 0.1)
        )
        app = definition.compile(checkpointer: adapter)
        request = app.durable_runner.fetch(
          thread: "thread.crash",
          request_id: "request.crash"
        )
        assert_includes %i[claimed running], request.status
        execution_id = request.execution_id
        recovered = app.durable_runner.recover(
          thread: "thread.crash",
          request_id: "request.crash",
          owner_id: "owner.recovery.#{point}"
        )
        assert_equal :completed, recovered.status
        assert_equal execution_id, recovered.execution_id
        assert_equal ["once"], app.state(thread: "thread.crash").state.fetch(:seen)
        assert_equal 1, history_execution_ids(app).uniq.length
        assert adapter.integrity_check.fetch("ok")
      ensure
        adapter&.close
      end
    end
  end

  def test_process_kill_after_durable_task_write_does_not_reexecute_node
    Dir.mktmpdir("tamoz-kill-pending-write") do |directory|
      path = File.join(directory, "tamoz.sqlite3")
      marker = File.join(directory, "node-calls")
      status = run_killed_child(
        path,
        "after_commit",
        operation: "checkpoint.append_writes",
        marker:
      )
      assert status.signaled?
      sleep 0.12

      adapter = Tamoz::SQLite::Adapter.new(
        path:,
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 0.1)
      )
      app = marker_definition(marker).compile(checkpointer: adapter)
      recovered = app.durable_runner.recover(
        thread: "thread.crash",
        request_id: "request.crash",
        owner_id: "owner.pending-recovery"
      )
      assert_equal :completed, recovered.status
      assert_equal ["once"], app.state(thread: "thread.crash").state.fetch(:seen)
      assert_equal ["x"], File.readlines(marker, chomp: true)
      assert adapter.integrity_check.fetch("ok")
    ensure
      adapter&.close
    end
  end

  def test_two_processes_racing_for_one_namespace_have_one_live_fence
    Dir.mktmpdir("tamoz-lease-race") do |directory|
      path = File.join(directory, "tamoz.sqlite3")
      bootstrap = Tamoz::SQLite::Adapter.new(path:)
      bootstrap.close

      children = %w[owner.a owner.b].map do |owner|
        spawn_lease_child(path, owner)
      end
      children.each { |child| child.fetch(:input).write("go") }
      children.each { |child| child.fetch(:input).close }
      outputs = children.map do |child|
        output = child.fetch(:output).read
        child.fetch(:output).close
        _pid, status = Process.wait2(child.fetch(:pid))
        assert status.success?
        output
      end
      assert_equal 1, outputs.count { |output| output.start_with?("acquired:") }
      assert_equal 1, outputs.count("conflict")

      adapter = Tamoz::SQLite::Adapter.new(path:)
      encoded = Tamoz::SQLite.const_get(:Wire, false).namespace([])
      row = adapter.__send__(:read, operation: "test.lease") do |tx|
        tx.first(
          "test.lease",
          <<~SQL,
            SELECT lease_owner_id, lease_fence
            FROM tamoz_namespaces
            WHERE thread_id = ? AND namespace = ?
          SQL
          ["thread.race", encoded]
        )
      end
      assert_nil row.fetch(0)
      assert_equal 1, row.fetch(1)
      assert adapter.integrity_check.fetch("ok")
    ensure
      adapter&.close
    end
  end

  private

  def run_killed_child(path, point, operation: "checkpoint.commit", marker: nil)
    load_paths = %w[tamoz-core tamoz-graph tamoz-sqlite].flat_map do |gem|
      ["-I", ROOT.join("gems", gem, "lib").to_s]
    end
    pid = Process.spawn(
      {
        "TAMOZ_DB_PATH" => path,
        "TAMOZ_KILL_POINT" => point,
        "TAMOZ_KILL_OPERATION" => operation,
        "TAMOZ_MARKER_PATH" => marker,
        "RUBYOPT" => nil
      },
      RbConfig.ruby,
      *load_paths,
      "-e",
      CHILD,
      out: File::NULL,
      err: File::NULL
    )
    _pid, status = Process.wait2(pid)
    status
  end

  def history_execution_ids(app)
    app.history(thread: "thread.crash", limit: 100).map(&:execution_id)
  end

  def definition
    Tamoz.graph(name: "crash-recovery", version: "1") do
      state :input, default: ""
      state :seen, reduce: :append, default: []
      node(:record, implementation_name: "crash.record", version: "1") do |state, _context|
        {seen: [state.fetch(:input)]}
      end
      edge Tamoz::START, :record
      edge :record, Tamoz::END
    end
  end

  def marker_definition(marker)
    Tamoz.graph(name: "crash-recovery", version: "1") do
      state :input, default: ""
      state :seen, reduce: :append, default: []
      node(:record, implementation_name: "crash.record", version: "1") do |state, _context|
        File.open(marker, "ab") { |file| file.write("x\n") }
        {seen: [state.fetch(:input)]}
      end
      edge Tamoz::START, :record
      edge :record, Tamoz::END
    end
  end

  def spawn_lease_child(path, owner)
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    load_paths = %w[tamoz-core tamoz-graph tamoz-sqlite].flat_map do |gem|
      ["-I", ROOT.join("gems", gem, "lib").to_s]
    end
    pid = Process.spawn(
      {
        "TAMOZ_DB_PATH" => path,
        "TAMOZ_OWNER" => owner,
        "RUBYOPT" => nil
      },
      RbConfig.ruby,
      *load_paths,
      "-e",
      LEASE_CHILD,
      in: input_reader,
      out: output_writer,
      err: File::NULL
    )
    input_reader.close
    output_writer.close
    {pid:, input: input_writer, output: output_reader}
  end
end

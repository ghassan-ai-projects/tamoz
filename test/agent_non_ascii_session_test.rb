# frozen_string_literal: true

require_relative "test_helper"
require "digest"

# P15-F (ledger gap 11) — the corpus can see non-ASCII content.
#
# D-10 crashed EVERY real durable session on any non-ASCII model reply and was
# invisible to 1122 green tests, because every scripted case and every SQLite
# suite used ASCII fixtures: the canonicality comparison was only ever exercised
# on its passing branch. Round 28 fixed the six comparison sites and added one
# unit-level regression test on the effect journal. This is the missing half —
# the same bytes driven through the WHOLE durable path a real session takes:
#
#   model reply -> checkpoint -> resume -> effect intent -> journal receipt ->
#   workspace bytes -> check receipt -> verification -> session view.
#
# Every payload here is chosen to break a different assumption: an em dash
# (multi-byte, not ASCII, common in real model prose), a curly quote, an
# accented Latin letter, an emoji outside the BMP, and a CJK ideograph.
class AgentNonAsciiSessionTest < Minitest::Test
  # Deliberately not a constant string in one encoding: each of these has bitten
  # a real system somewhere.
  EM_DASH = "—"
  CURLY = "don’t"
  ACCENT = "café"
  EMOJI = "🚀"
  CJK = "日本語"
  ANSWER = "#{ACCENT} #{EM_DASH} #{CURLY} #{EMOJI} #{CJK}"

  class ScriptedModel
    def initialize(plan:, review:, verify:)
      @responses = {plan:, review:, verify:}.transform_values(&:dup)
    end

    def generate(stage:, system:, prompt:)
      queue = @responses.fetch(stage)
      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  # The D-10 crash path exactly: a non-ASCII model reply must survive the
  # durable round trip. Before the fix this raised
  # `CheckpointCorruptionError: … payload is not canonical` against bytes that
  # were never corrupted.
  def test_a_non_ascii_model_reply_survives_the_durable_round_trip
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "#{ACCENT}\n", encoding: Encoding::UTF_8)
      session = build_session(
        model: ScriptedModel.new(
          plan: [read_plan],
          review: [accepted],
          verify: [{"answer" => ANSWER, "satisfied" => true,
                    "evidence" => ["note.txt #{EM_DASH} read"]}]
        ),
        root:, adapter:
      )

      outcome = session.start("read the note", thread: "nonascii", request_id: "r0")

      assert_equal :completed, outcome.status
      assert_equal ANSWER, outcome.result.answer
      assert_equal Encoding::UTF_8, outcome.result.answer.encoding
      assert outcome.result.answer.valid_encoding?

      # The bytes must come back identical from the DURABLE store, not from the
      # in-memory object that just wrote them.
      view = session.view(thread: "nonascii")

      assert_equal ANSWER, view.state.fetch(:verification).fetch("answer")
      assert_equal ANSWER.b, view.state.fetch(:verification).fetch("answer").b
      assert_equal ["note.txt #{EM_DASH} read"],
                   view.state.fetch(:verification).fetch("evidence")
    end
  end

  # A fresh Session over the same database — the ordinary resume path — reads
  # the same bytes. This is the seam D-10 actually died at: the decode, not the
  # encode.
  def test_a_non_ascii_thread_reopens_from_a_fresh_session
    Dir.mktmpdir("tamoz-nonascii-resume") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "note.txt"), "#{CJK}\n", encoding: Encoding::UTF_8)
      database = File.join(directory, "tamoz.sqlite3")

      with_adapter(database) do |adapter|
        session = build_session(
          model: ScriptedModel.new(
            plan: [read_plan], review: [accepted],
            verify: [{"answer" => ANSWER, "satisfied" => true, "evidence" => [EMOJI]}]
          ),
          root:, adapter:
        )
        assert_equal :completed,
                     session.start("read", thread: "reopen", request_id: "r0").status
      end

      with_adapter(database) do |adapter|
        session = build_session(
          model: ScriptedModel.new(plan: [read_plan], review: [accepted], verify: [{}]),
          root:, adapter:
        )
        view = session.view(thread: "reopen")

        assert_equal :completed, view.status
        assert_equal ANSWER, view.state.fetch(:verification).fetch("answer")
        assert_equal [EMOJI], view.state.fetch(:verification).fetch("evidence")
        # The resume guards read the same record and stay silent.
        session.verify_skill_binding!(thread: "reopen")
        session.verify_mcp_binding!(thread: "reopen")
      end
    end
  end

  # Non-ASCII bytes through the EFFECT path: a reviewed patch writes them, the
  # journal records the receipt, and the workspace holds exactly the approved
  # bytes. The check reads them back and its output is non-ASCII too, so the
  # receipt itself carries multi-byte content into the journal.
  def test_a_reviewed_patch_writes_non_ascii_bytes_and_the_receipt_round_trips
    with_workspace do |root, adapter|
      original = "greeting = \"hello\"\n"
      File.write(File.join(root, "app.rb"), original, encoding: Encoding::UTF_8)
      check = [
        RbConfig.ruby, "-e",
        <<~CHECK
          content = File.read("app.rb", encoding: Encoding::UTF_8)
          abort("missing") unless content.include?(#{ACCENT.dump})
          $stdout.write(#{"#{ACCENT} #{EMOJI} ok\n".dump})
        CHECK
      ]
      session = build_session(
        model: ScriptedModel.new(
          # Discovery first, exactly as the real loop asks for it: the action
          # plan is only requested after the read-only phase closes.
          plan: [read_plan("app.rb"), patch_plan(Digest::SHA256.hexdigest(original))],
          review: [accepted],
          verify: [{"answer" => ANSWER, "satisfied" => true, "evidence" => ["app.rb"]}]
        ),
        root:, adapter:, allow_changes: true, checks: {"answer" => check}
      )

      outcome = approve_all(
        session,
        session.start("greet in French", thread: "patched", request_id: "r0"),
        thread: "patched", request_id: "r0"
      )

      assert_equal :completed, outcome.status, outcome.blocked.inspect
      assert_equal "greeting = \"#{ACCENT}\"\n",
                   File.read(File.join(root, "app.rb"), encoding: Encoding::UTF_8)

      view = session.view(thread: "patched")

      # Every effect the run journalled succeeded — nothing went `:unknown`
      # because a multi-byte payload failed a canonicality comparison.
      refute_empty view.effect_receipts
      assert_equal ["succeeded"], view.effect_receipts.map { |r| r.fetch("status") }.uniq

      # The observations are the durable, model-visible text: they pass through
      # the checkpoint codec, which is exactly where D-10 forged a corruption
      # error. The check's non-ASCII stdout must come back byte-identical.
      outputs = view.state.fetch(:observations).filter_map { |record| record["output"] }

      refute_empty outputs
      assert(outputs.any? { |output| output.include?("#{ACCENT} #{EMOJI} ok") },
             "the non-ASCII check output must round-trip: #{outputs.inspect}")
      outputs.each do |output|
        assert_equal Encoding::UTF_8, output.encoding
        assert output.valid_encoding?, "a durable observation must stay valid UTF-8"
      end
      assert_equal "check_passed", view.terminal.fetch("reason")
    end
  end

  # Round 28 fixed SIX canonicality comparison sites; the corpus reached only
  # one of them with non-ASCII bytes. These drive the remaining five, each
  # verified by reverting its `.b` comparison and watching this file go red.
  #
  #   checkpoint_store#decode_request      — a non-ASCII TASK is a request payload
  #   checkpoint_store#canonical_state_value — durable state read back
  #   Store#get                            — the application store's own values
  #   CheckpointCodec#canonical_value_bytes / #load_value — the checkpoint itself
  def test_a_non_ascii_task_round_trips_through_the_durable_request_payload
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "#{CJK}\n", encoding: Encoding::UTF_8)
      session = build_session(
        model: ScriptedModel.new(
          plan: [read_plan], review: [accepted],
          verify: [{"answer" => ANSWER, "satisfied" => true, "evidence" => [CJK]}]
        ),
        root:, adapter:
      )
      # The TASK itself is non-ASCII: it becomes the durable request payload,
      # which is decoded and canonicality-checked on every claim and recovery.
      task = "explique #{ACCENT} #{EM_DASH} #{EMOJI}"

      outcome = session.start(task, thread: "task", request_id: "r0")

      assert_equal :completed, outcome.status
      view = session.view(thread: "task")

      assert_equal task, view.state.fetch(:task)
      assert_equal task.b, view.state.fetch(:task).b
      # …and the request record itself decodes cleanly a second time.
      request = session.app.durable_runner.fetch(thread: "task", request_id: "r0")

      assert_equal :completed, request.status
      assert_equal task, request.payload.fetch("task")
    end
  end

  def test_the_application_store_round_trips_non_ascii_values
    Dir.mktmpdir("tamoz-nonascii-store") do |directory|
      with_adapter(File.join(directory, "tamoz.sqlite3")) do |adapter|
        store = adapter.store
        store.put("memory", "greeting", {"text" => ANSWER, "n" => [EMOJI]})
        entry = store.get("memory", "greeting")

        assert_equal({"text" => ANSWER, "n" => [EMOJI]}, entry.value)
        assert_equal ANSWER.b, entry.value.fetch("text").b
        assert_equal Encoding::UTF_8, entry.value.fetch("text").encoding

        # A second read goes through the same canonicality comparison against
        # the stored BLOB, which is where ASCII-8BIT vs UTF-8 bites.
        assert_equal entry.value, store.get("memory", "greeting").value
      end
    end
  end

  # The canonicality comparison is a defect CLASS, not one bug: D-10 lived at
  # six sites at once, and fixing only the crashing one would have moved the
  # crash. This pins the whole set, so a NEW comparison cannot be added without
  # someone deciding whether the corpus can see it.
  #
  # Coverage measured by reverting each site's `.b` comparison and re-running
  # this file:
  #
  #   effect_journal#decode_receipt          COVERED (the D-10 crash site)
  #   checkpoint_store#decode_request        COVERED (a non-ASCII task payload)
  #   store#get                              COVERED (application store values)
  #   checkpoint_codec#load_value            COVERED (durable state values)
  #   checkpoint_codec#canonical_value_bytes shadowed — `load_value` performs the
  #     identical check first, so this one can never be the site that fires
  #   checkpoint_store#canonical_state_value unreachable — it guards a request's
  #     `response` and `terminal_error`, whose vocabularies are ASCII by
  #     construction (`{"graph_status" => …}`, the typed DR-4 payloads)
  #   wire#decode_namespace                  unreachable — namespace parts are
  #     component ids; non-ASCII is refused before this comparison
  #
  # The last three are defence in depth. They are named here so the boundary is
  # a recorded decision rather than an accident.
  CANONICALITY_SITES = {
    "tamoz-graph/lib/tamoz/graph/checkpoint_codec.rb" => 2,
    "tamoz-sqlite/lib/tamoz/sqlite/wire.rb" => 1,
    "tamoz-sqlite/lib/tamoz/sqlite/effect_journal.rb" => 1,
    "tamoz-sqlite/lib/tamoz/sqlite/checkpoint_store.rb" => 2,
    "tamoz-sqlite/lib/tamoz/sqlite/store.rb" => 1
  }.freeze

  def test_every_canonicality_comparison_site_is_accounted_for
    observed = Hash.new(0)
    Dir[ROOT.join("gems", "*", "lib", "**", "*.rb")].sort.each do |path|
      count = File.read(path, encoding: Encoding::UTF_8).scan(/\.b ==/).length
      next if count.zero?

      observed[path.delete_prefix("#{ROOT.join("gems")}/")] = count
    end

    assert_equal CANONICALITY_SITES, observed,
                 "a canonicality comparison was added or moved: decide whether a " \
                 "non-ASCII payload can reach it, then update this map and the " \
                 "coverage note above"
  end

  # Digest stability: the same non-ASCII value must digest identically however
  # it arrived. A comparison that ignored encoding (D-10's shape) or a
  # normalization that rewrote the bytes would break exactly here.
  def test_non_ascii_record_digests_are_byte_stable
    utf8 = ANSWER.dup.force_encoding(Encoding::UTF_8)
    from_bytes = ANSWER.b.force_encoding(Encoding::UTF_8)

    assert_equal utf8, from_bytes
    assert_equal(
      Tamoz::Agent::SessionRecords.digest({"answer" => utf8}),
      Tamoz::Agent::SessionRecords.digest({"answer" => from_bytes})
    )
    # …and a DIFFERENT non-ASCII value must not collide with it.
    refute_equal(
      Tamoz::Agent::SessionRecords.digest({"answer" => utf8}),
      Tamoz::Agent::SessionRecords.digest({"answer" => "#{utf8}!"})
    )
  end

  private

  def read_plan(path = "note.txt")
    {
      "goal" => "read #{path}",
      "done_when" => ["the file was read"],
      "steps" => [
        {"id" => "s1", "purpose" => "read it", "tool" => "read_file",
         "arguments" => {"path" => path},
         "verification" => "the content is returned"}
      ]
    }
  end

  def patch_plan(digest)
    {
      "goal" => "greet in French",
      "done_when" => ["the check passes"],
      "steps" => [
        {"id" => "edit", "purpose" => "apply the exact replacement",
         "tool" => "apply_patch",
         "arguments" => {"path" => "app.rb", "expected_sha256" => digest,
                         "before" => "hello", "after" => ACCENT},
         "verification" => "the receipt reports the new digest"},
        {"id" => "check", "purpose" => "run the configured check",
         "tool" => "run_check", "arguments" => {"name" => "answer"},
         "verification" => "the check exits zero"}
      ]
    }
  end

  def accepted
    {"decision" => "accept", "issues" => [], "rationale" => "bounded and checked"}
  end

  def with_workspace
    Dir.mktmpdir("tamoz-nonascii") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      with_adapter(File.join(directory, "tamoz.sqlite3")) do |adapter|
        yield File.realpath(root), adapter
      end
    end
  end

  def with_adapter(path)
    adapter = Tamoz::SQLite::Adapter.new(
      path:, limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.5)
    )
    begin
      yield adapter
    ensure
      adapter.close
    end
  end

  def build_session(model:, root:, adapter:, allow_changes: false, checks: {})
    Tamoz::Agent::Session.new(
      model:,
      toolbox: Tamoz::Tools::Toolbox.new(root:, allow_changes:, checks:),
      checkpointer: adapter
    )
  end

  def approve_all(session, outcome, thread:, request_id:, limit: 8)
    current = outcome
    index = 0
    while current.status == :paused && index < limit
      index += 1
      interrupt = session.view(thread:).interrupts.first
      break unless interrupt

      current = session.resume(
        {interrupt.task_id => {0 => true}},
        thread:, request_id: "#{request_id}.#{index}"
      )
    end
    current
  end
end

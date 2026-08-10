# frozen_string_literal: true

require "digest"
require "monitor"
require "time"

require_relative "worker_runtime/deferred_model"

module Tamoz
  module Agent
    # The opened form of a runtime directory: one SQLite adapter, the stores bound
    # over it, and the sessions the worker drives.
    #
    # `RuntimeDirectory` is inert configuration and knows nothing about storage.
    # This is where that configuration becomes running machinery, and it is the
    # only place in the worker path that opens a database.
    #
    # One adapter, shared. Schedules, request inboxes and checkpoints live in the
    # same file precisely so the schedule store can claim an occurrence and
    # enqueue its request in a single transaction.
    class WorkerRuntime
      class Error < Tamoz::Agent::Error; end

      # A durable read or write this runtime could not complete.
      #
      # Separate from `Error` (which means "the operator configured something
      # impossible" and is permanent) because callers must treat the two
      # differently: an unavailable store is precisely the situation in which a
      # gate has to REFUSE rather than guess, and it may clear on the next poll.
      class StoreUnavailableError < Error; end

      attr_reader :directory, :adapter, :delivery_sink

      def self.open(directory, model_factory:, lease_ttl: 30.0, delivery_sink: nil)
        # Deferred exactly as `run_durable` defers it: tamoz-agent must not load
        # the storage or channel packages at require time.
        require "tamoz/sqlite"
        require "tamoz/comms"
        new(directory, model_factory:, lease_ttl:, delivery_sink:)
      end

      def initialize(directory, model_factory:, lease_ttl: 30.0, delivery_sink: nil)
        @directory = directory
        @model_factory = model_factory
        # The channel projection is nil-safe by default (ADR-042): a worker
        # without a comms surface delivers nothing and never raises.
        @delivery_sink = delivery_sink || Tamoz::Comms::DeliverySink.null
        # The memory codec is the default codec PLUS one registration for
        # MemoryRecord, so it decodes everything the default could. Installing it
        # only when memory is enabled keeps a runtime that never asked for memory
        # byte-identical to what it was before.
        codec = directory.enabled_sources.include?("memory") ? Memory::Surface.codec : nil
        @adapter = Tamoz::SQLite::Adapter.new(
          path: directory.database_path,
          limits: Tamoz::SQLite::Limits.new(lease_ttl:),
          **(codec ? {state_codec: codec} : {})
        )
        @sessions = {}
        @profiles = {}
        # A Monitor, not a Mutex: `build_session` runs under this lock and asks
        # for `profile`, which takes it again. Ruby's Mutex is not reentrant, so
        # that same-thread re-entry would deadlock the worker outright.
        @monitor = Monitor.new
      end

      def path = @directory.path

      def close
        @adapter.close unless @adapter.closed?
      end

      # The bound checkpoint store. Taken from a session rather than bound
      # separately so the worker reads the inbox through exactly the codec the
      # sessions write it with.
      def checkpoints = canonical_session.app.checkpointer

      def schedule_store
        @schedule_store ||= @adapter.bind_schedule_store(checkpoints)
      end

      # What the worker itself is allowed to do right now. A schedule's claim-time
      # grant is intersected with this, so scheduled authority can never exceed
      # the authority the operator currently gives the worker — a schedule written
      # last month cannot outrank today's configuration.
      def worker_grant
        {"scopes" => ["read"], "capabilities" => @directory.enabled_sources}
      end

      # Which trusted profile a thread runs under.
      #
      # This binding lives in the operator's runtime database, written when the
      # work was submitted — NOT in the request payload. Two reasons, and both
      # matter:
      #
      #   - The payload is graph state. Its keys are the session's declared state
      #     channels, and an extra key is a hard error rather than a silent
      #     passenger.
      #   - Authority must not travel with the work item. A queued payload is data;
      #     if it could name its own authority it would be one deserialization bug
      #     away from choosing it. The thread's authority is recorded once, by the
      #     command the operator ran, in a store only the operator can write.
      #
      # The binding names a profile; the profile's CONTENT always comes from the
      # runtime directory. Work can say "run me as `trusted`", and can never say
      # what `trusted` permits.
      THREAD_BINDINGS = %w[tamoz worker thread_profile].freeze

      def bind_thread_profile(thread_id, profile_id)
        return if profile_id.nil?

        upsert(THREAD_BINDINGS, thread_id, {"profile" => profile_id})
      end

      # A schedule's task text, addressed by the digest its `payload_ref` records.
      # Stored in the operator's runtime database, so the thing a schedule will
      # ask for cannot be rewritten by the workspace the agent works on.
      SCHEDULE_PAYLOADS = %w[tamoz scheduler payload].freeze
      SCHEDULE_TOMBSTONES = %w[tamoz scheduler tombstone].freeze

      def store_schedule_payload(schedule_id, task)
        text = String(task)
        digest = "sha256:#{Digest::SHA256.hexdigest("tamoz.scheduler.payload.v1\n#{text}")}"
        upsert(SCHEDULE_PAYLOADS, schedule_id, {"task" => text, "digest" => digest})
        digest
      end

      def schedule_payload(schedule_id)
        durable("schedule payload #{schedule_id.inspect}") do
          record(SCHEDULE_PAYLOADS, schedule_id)&.fetch("task", nil)
        end
      end

      # A removed schedule is disabled AND tombstoned, so a later `schedule add`
      # with the same id cannot silently inherit the removed one's stored task.
      #
      # The delete is the half that matters and its failure is NOT swallowed: a
      # tombstone written over a surviving payload is exactly the state this
      # method exists to prevent.
      def tombstone_schedule(schedule_id)
        durable("schedule tombstone #{schedule_id.inspect}") do
          upsert(SCHEDULE_TOMBSTONES, schedule_id, {"removed_at" => Time.now.utc.iso8601})
          # The store is versioned: a delete without the head version is a
          # blind write and the CAS refuses it. This delete therefore failed on
          # EVERY removal, and the blanket rescue that used to sit here turned
          # that into silence — the tombstone was written and the task text it
          # was supposed to retire stayed in the store.
          store = @adapter.store
          version = store.head_version(SCHEDULE_PAYLOADS, schedule_id)
          store.delete(SCHEDULE_PAYLOADS, schedule_id, if_version: version) if version
        end
      end

      # The occurrence a thread is currently working on.
      #
      # This exists because a turn that stops to ask a human COMPLETES its
      # request: the request was delivered and ran: it is the SESSION that is
      # paused, not the request. So the inbox goes empty while the work is very
      # much unfinished, and neither the inbox nor an in-memory set in the worker
      # can answer "what is still open" across a restart.
      #
      # The record is opened when the worker claims and closed when the thread
      # reaches a terminal state, so it is also the durable identity that lets an
      # approval resume the SAME occurrence rather than starting a new one.
      OPEN_OCCURRENCES = %w[tamoz worker occurrence].freeze

      def open_occurrence(thread_id, occurrence_id)
        upsert(OPEN_OCCURRENCES, thread_id,
               {"occurrence_id" => occurrence_id, "opened_at" => Time.now.utc.iso8601})
      end

      def close_occurrence(thread_id)
        durable("open occurrence for #{thread_id.inspect}") do
          @adapter.store.delete(OPEN_OCCURRENCES, thread_id,
                                if_version: @adapter.store.head_version(OPEN_OCCURRENCES, thread_id))
        end
      end

      def occurrence_for(thread_id)
        durable("open occurrence for #{thread_id.inspect}") do
          record(OPEN_OCCURRENCES, thread_id)&.fetch("occurrence_id", nil)
        end
      end

      def open_occurrences(limit: 500)
        durable("open occurrences") do
          @adapter.store.each(OPEN_OCCURRENCES, limit:).map do |entry|
            {thread_id: entry.key, occurrence_id: entry.value["occurrence_id"]}
          end
        end
      end

      # How much of a thread's budget has been spent, measured from durable
      # evidence rather than from anything the run reports about itself.
      #
      # Model calls are counted from the effect journal: every model call is
      # dispatched as an effect with operation `model.generate.<stage>`, so the
      # journal is already an accurate, crash-surviving ledger. Wall clock is
      # measured from the occurrence record the worker opened at claim time.
      #
      # Nothing the agent produces participates in either number. There is no
      # state channel, tool or model output that reaches them, which is what
      # "the agent may never widen its own budget" has to mean structurally.
      # The budgets governing a thread, from the profile bound to it. Operator
      # authority, resolved the same way every other authority decision is.
      # `nil` here means one thing only: this profile asked for no ceiling. It
      # must never mean "the profile could not be read" — that answer would
      # convert a bounded thread into an unbounded one at the moment the store
      # got sick, which is precisely when a ceiling matters most.
      def thread_budgets(thread_id)
        durable("budgets for #{thread_id.inspect}") do
          resolved = profile(thread_profile(thread_id))
          resolved && resolved.budgets
        end
      end

      def budget_usage(thread_id)
        durable("budget usage for #{thread_id.inspect}") do
          model_calls = checkpoints.effect_census.count do |row|
            row[:thread_id] == thread_id && row[:operation].to_s.start_with?("model.generate")
          end
          {"model_calls" => model_calls, "wall_clock_seconds" => occurrence_age_seconds(thread_id)}
        end
      end

      def occurrence_age_seconds(thread_id)
        durable("occurrence age for #{thread_id.inspect}") do
          opened = record(OPEN_OCCURRENCES, thread_id)&.fetch("opened_at", nil)
          next 0.0 unless opened

          (Time.now.utc - Time.parse(opened)).to_f
        end
      end

      # A stop caused by a spent budget. Durable so `tamoz status` can report it
      # after the worker has exited, and keyed by occurrence so an operator can
      # see which piece of work hit which ceiling.
      BUDGET_EXHAUSTIONS = %w[tamoz worker budget_exhaustion].freeze

      def record_budget_exhaustion(thread_id, occurrence_id, budget:, detail:)
        upsert(BUDGET_EXHAUSTIONS, "#{thread_id}/#{occurrence_id}",
               {"thread_id" => thread_id, "occurrence_id" => occurrence_id,
                "budget" => budget, "detail" => String(detail)[0, 500],
                "stopped_at" => Time.now.utc.iso8601})
      end

      def budget_exhaustions(limit: 500)
        durable("budget exhaustions") do
          @adapter.store.each(BUDGET_EXHAUSTIONS, limit:).map { |entry| entry.value }
        end
      end

      # Human decisions about paused work, recorded by `tamoz approve` and the
      # channel gateway, consumed by the worker.
      #
      # A decision is DURABLE and binds the exact interrupt set it answers
      # (interrupt_digest), so a decision for one question can never answer a
      # later one in the same occurrence (design §9). Records live in the
      # runtime database through the Comms DecisionStore contract; the worker
      # only reads, claims and consumes them. There is no code path that writes
      # one on the worker's behalf, which is what makes "headless never becomes
      # approval" a structural property rather than a promise.
      DECISION_CLAIM_TTL_S = 30.0

      def decision_store
        @decision_store ||= @adapter.bind_comms_decision_store
      end

      # The newest unexpired pending decision matching the exact interrupt set,
      # or nil. `nil` means "no human has answered yet" and nothing else; a
      # read error must not borrow that meaning, or a recorded approval would
      # leave the work parked forever with no signal anywhere.
      # :reek:LongParameterList -- mirrors the DecisionStore contract signature.
      def pending_decision(thread_id, occurrence_id, interrupt_digest:, now:)
        durable("decision for #{thread_id.inspect}/#{occurrence_id.inspect}") do
          wire = decision_store.pending_decision_for(
            thread_id:, occurrence_id:, interrupt_digest:, now:
          )
          wire && Tamoz::Comms::DecisionRecord.from_wire(wire)
        end
      end

      # Fenced lease on one decision. An expired claim lease releases the
      # record back to claimable, so a crash before the resume enqueue is
      # recovered by re-claiming on the next pass — never by duplicating work.
      # :reek:LongParameterList -- mirrors the DecisionStore contract signature.
      def claim_decision(decision_id, owner:, fence:, now:)
        durable("claim decision #{decision_id.inspect}") do
          decision_store.claim_decision(
            decision_id:, owner:, fence:,
            claim_expires_at: now + DECISION_CLAIM_TTL_S, now:
          )
        end
      end

      def consume_decision(decision_id, now:)
        durable("consume decision #{decision_id.inspect}") do
          decision_store.consume_decision(decision_id:, now:)
        end
      end

      # The operator/CLI side of the contract: writes one pending decision.
      def record_decision(record)
        durable("record decision for #{record.thread_id.inspect}") do
          decision_store.insert_decision(record.wire)
        end
      end

      # The runtime store is versioned and refuses a blind second write. These
      # records are operator configuration that legitimately changes — a schedule
      # gets a new task, a thread a new profile — so writing one means replacing
      # the current version, not adding a first one.
      def upsert(namespace, key, value)
        @adapter.store.put(namespace, key, value,
                           if_version: @adapter.store.head_version(namespace, key))
      end

      # Every durable read and write in this file goes through here.
      #
      # The rule this replaces a set of blanket rescues with: a gate that cannot
      # reach its evidence REFUSES; it never assumes the permissive answer.
      # Returning `nil`/`[]`/zeros on a storage failure turned "we do not know
      # what this thread has spent" into "it has spent nothing" — the one answer
      # that lets an unattended run spend without a ceiling — and turned "the
      # human's approval could not be read" into "no human has answered".
      #
      # So the failure keeps an identity and reaches the caller. The worker's
      # per-thread containment parks that thread, the schedule pass reports a
      # `schedule.error`, and an operator sees a real error instead of a
      # healthy-looking zero. Configuration errors (`Error`, e.g. an unknown
      # profile) pass through unchanged: they are already the right answer.
      def durable(what)
        yield
      rescue Error
        raise
      rescue StandardError => error
        raise StoreUnavailableError, "#{what} is unavailable: #{error.class}: #{error.message}"
      end

      # The record at (namespace, key), or nil when there is none.
      #
      # `Store#get` does NOT return nil for a deleted key: the head row
      # survives as a tombstone and the entry comes back with `deleted` set and
      # a nil value. Every reader here wants "is there a record", so the check
      # lives once instead of six `entry && entry.value["x"]` chains that all
      # raise NoMethodError the moment their key is deleted.
      # :reek:FeatureEnvy :reek:NilCheck -- reading a StoreEntry's liveness IS
      # this method's entire job, and collapsing "absent" and "deleted" into one
      # nil is the point: no caller distinguishes them.
      def record(namespace, key)
        entry = @adapter.store.get(namespace, key)
        return nil if entry.nil? || entry.deleted

        entry.value
      end

      # `nil` means "this thread is bound to no profile", which the session
      # builder reads as read-only authority. An unreadable binding is NOT that:
      # silently downgrading it would run the work under the wrong authority
      # rather than refusing to run it.
      def thread_profile(thread_id)
        durable("profile binding for #{thread_id.inspect}") do
          record(THREAD_BINDINGS, thread_id)&.fetch("profile", nil)
        end
      end

      # The session that will drive `thread_id`, under the authority bound to it.
      def session_for(thread_id)
        session_for_profile(thread_profile(thread_id))
      end

      def session_for_profile(profile_id)
        @monitor.synchronize do
          @sessions[profile_id] ||= build_session(profile_id)
        end
      end

      def canonical_session = session_for_profile(nil)

      # The capability names the agent can actually dispatch, read off the sealed
      # registry rather than off configuration. This is the honest answer to "is
      # websearch really available?", and it is deliberately not the same value as
      # `RuntimeDirectory#enabled_sources`.
      def capability_catalog
        durable("capability catalog") { canonical_session.capabilities.names(:action).sort }
      end

      def head_request(thread_id)
        entry = checkpoints.pending_threads(limit: 200)
                           .find { |row| row.fetch(:thread_id) == thread_id }
        return nil unless entry

        checkpoints.fetch_request(thread_id:, request_id: entry.fetch(:head_request_id))
      end

      # A profile id names a file inside the runtime directory, so it is a
      # filename and nothing more. Anything with a separator, a traversal segment,
      # or an exotic character is refused before it reaches the filesystem —
      # `../../somewhere/else` must never resolve to a profile.
      PROFILE_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_\-.]{0,63}\z/
      RESERVED_PROFILE_IDS = %w[. ..].freeze

      # A profile named by a request must exist in the runtime directory. An
      # unknown name is refused rather than silently downgraded to "no profile" —
      # a typo must not quietly become weaker authority that still runs.
      #
      # Memoized under the same monitor as `session_for_profile`, because
      # `Profile.load` WRITES the adoption registry: with `concurrency > 1` an
      # unguarded memo is two threads writing one file, not merely duplicated
      # work.
      def profile(profile_id)
        return nil if profile_id.nil?

        @monitor.synchronize { @profiles[profile_id] ||= load_profile(profile_id) }
      end

      def load_profile(profile_id)
        path = profile_path(profile_id)
        unless File.exist?(path)
          raise Error, "profile #{profile_id.inspect} is not in #{@directory.profiles_path}"
        end

        # Auto-adopted, and only because of where it lives. `Profile.load`
        # still enforces private permissions, a symlink-safe read, and that the
        # profile sits OUTSIDE the workspace it grants authority over. On top of
        # that, this file is inside a 0700 runtime directory that only the
        # operator can write. The interactive adoption prompt exists to stop an
        # untrusted CHECKOUT from supplying authority; nothing here came from a
        # checkout. A worker has no terminal to prompt at, and prompting is not
        # something to fake.
        Profile.load(path, env: {"TAMOZ_CONFIG_HOME" => @directory.path},
                           confirm_adoption: ->(_document) { true })
      end

      def profile_path(profile_id)
        id = String(profile_id)
        if RESERVED_PROFILE_IDS.include?(id) || !PROFILE_ID_PATTERN.match?(id)
          raise Error,
                "profile id #{profile_id.inspect} is not a valid name " \
                "(letters, digits, underscore, dash and dot only)"
        end

        path = File.join(@directory.profiles_path, "#{id}.yaml")
        expanded = File.expand_path(path)
        root = File.expand_path(@directory.profiles_path)
        unless expanded.start_with?("#{root}#{File::SEPARATOR}")
          raise Error, "profile id #{profile_id.inspect} escapes #{root}"
        end

        expanded
      end

      # What this profile makes the worker stop and ask about.
      #
      # The interactive CLI asks a human about `tools.approval_required`. A worker
      # has no human to ask, so it asks about everything the profile has not
      # explicitly PREAUTHORIZED for unattended use — which is a strictly larger
      # set, never a smaller one. Both lists are unioned so a tool marked
      # approval-required interactively can never become automatic just because
      # nobody is watching.
      #
      # The whole computation reads from the profile bound to this exact digest.
      # Nothing the model says, no repository file, no skill, no MCP descriptor
      # and no memory record participates.
      def unattended_approval_required(profile)
        (profile.tools_approval_required | profile.unattended_requires_approval).uniq
      end

      # The compiled skill snapshot, or the empty one.
      #
      # Skills are only ever DISCOVERED from the operator's own directory — never
      # by scanning the workspace. A skill body is instructions the agent will
      # follow, so letting the tree under repair supply one would be the plainest
      # possible content-grants-authority failure.
      #
      # Compiling produces a content-addressed snapshot; rejections are kept so an
      # operator can see what was refused rather than wondering why a skill never
      # appeared.
      def skills_snapshot
        return Skills::Snapshot.empty unless @directory.enabled_sources.include?("skills")

        @skills_snapshot ||= begin
          root = @directory.skills_root
          if File.directory?(root)
            Skills::Compiler.new(
              sources: [Skills::SkillSource.new(id: "operator", root:, trust: "operator", precedence: 0)]
            ).compile
          else
            Skills::Snapshot.empty
          end
        end
      end

      # The three-layer memory engine, when the operator asked for one.
      #
      # `tenant` scopes the memory namespace and `owner` is the identity episodes
      # are admitted under; both come from operator configuration, never from a
      # task, a model, or the workspace. Memory is EVIDENCE the agent may read —
      # it is never allowed to alter policy, which is why nothing in this path
      # touches the profile or the capability surface.
      def memory_engine
        return nil unless @directory.enabled_sources.include?("memory")

        @memory_engine ||= Memory::Engine.new(
          tenant: @directory.source_settings("memory")["tenant"] || "default",
          adapter: @adapter
        )
      end

      def memory_owner
        @directory.source_settings("memory")["owner"] || "operator"
      end

      # What an operator needs to see about memory without a second UI: whether it
      # is on, and under which tenant/owner the episodes are being written.
      def memory_summary
        return {"enabled" => false} unless memory_engine

        {"enabled" => true, "tenant" => memory_engine.tenant, "owner" => memory_owner}
      rescue StandardError => error
        {"enabled" => false, "error" => error.message}
      end

      # The governed MCP source (which is also how websearch arrives), built once
      # per runtime because each server is a supervised subprocess.
      def mcp_source
        return @mcp_source if defined?(@mcp_source)

        @mcp_source = McpSourceBuilder.new(@directory).build
      end

      def skill_rejections
        skills_snapshot.respond_to?(:rejections) ? Array(skills_snapshot.rejections) : []
      end

      private

      def build_session(profile_id)
        resolved = profile(profile_id)
        toolbox = if resolved
                    Toolbox.new(
                      root: resolved.canonical_root,
                      allow_changes: resolved.allow_changes?,
                      checks: resolved.checks.transform_values { |check| check.fetch("argv") },
                      check_safeties: resolved.checks.transform_values { |check| check.fetch("safety").to_sym },
                      allowed_tools: resolved.tools_allowed,
                      approval_required: unattended_approval_required(resolved),
                      skills: skills_snapshot
                    )
                  else
                    # No profile means no preauthorization, so the only thing a
                    # worker may do unattended is read.
                    Toolbox.new(root: @directory.workspace_root, allow_changes: false,
                                checks: {}, skills: skills_snapshot)
                  end

        engine = memory_engine
        Session.new(
          model: DeferredModel.new { @model_factory.call(profile: resolved) },
          toolbox:,
          checkpointer: @adapter,
          profile: resolved,
          profile_budgets: resolved && resolved.budgets,
          memory: engine,
          memory_owner: engine && memory_owner,
          mcp: mcp_source
        )
      end
    end
  end
end

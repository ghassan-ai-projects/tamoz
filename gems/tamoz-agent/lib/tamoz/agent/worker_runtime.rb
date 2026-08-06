# frozen_string_literal: true

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

      # A model that is not built until something actually asks it to generate.
      #
      # `tamoz status` and `tamoz queue list` read durable state and never call a
      # model. Constructing sessions eagerly would make them fail on a machine
      # with no provider configured, which is exactly the machine an operator is
      # most likely to be debugging on. Deferring construction keeps inspection
      # working without giving the inspection path a second, weaker code path of
      # its own.
      class DeferredModel
        def initialize(&build)
          @build = build
          @monitor = Mutex.new
        end

        def generate(...)
          model.generate(...)
        end

        private

        def model
          @monitor.synchronize { @model ||= @build.call }
        end
      end

      attr_reader :directory, :adapter

      def self.open(directory, model_factory:, lease_ttl: 30.0)
        # Deferred exactly as `run_durable` defers it: tamoz-agent must not load
        # the storage package at require time.
        require "tamoz/sqlite"
        new(directory, model_factory:, lease_ttl:)
      end

      def initialize(directory, model_factory:, lease_ttl: 30.0)
        @directory = directory
        @model_factory = model_factory
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
        @monitor = Mutex.new
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
        entry = @adapter.store.get(SCHEDULE_PAYLOADS, schedule_id)
        entry && entry.value["task"]
      rescue StandardError
        nil
      end

      # A removed schedule is disabled AND tombstoned, so a later `schedule add`
      # with the same id cannot silently inherit the removed one's stored task.
      def tombstone_schedule(schedule_id)
        upsert(SCHEDULE_TOMBSTONES, schedule_id, {"removed_at" => Time.now.utc.iso8601})
        @adapter.store.delete(SCHEDULE_PAYLOADS, schedule_id)
      rescue StandardError
        nil
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
        @adapter.store.delete(OPEN_OCCURRENCES, thread_id,
                              if_version: @adapter.store.head_version(OPEN_OCCURRENCES, thread_id))
      rescue StandardError
        nil
      end

      def occurrence_for(thread_id)
        entry = @adapter.store.get(OPEN_OCCURRENCES, thread_id)
        entry && entry.value["occurrence_id"]
      rescue StandardError
        nil
      end

      def open_occurrences(limit: 500)
        @adapter.store.each(OPEN_OCCURRENCES, limit:).map do |entry|
          {thread_id: entry.key, occurrence_id: entry.value["occurrence_id"]}
        end
      rescue StandardError
        []
      end

      # Human decisions about paused work, recorded by `tamoz approve` and
      # consumed by the worker.
      #
      # A decision is DURABLE and keyed to the exact occurrence it answers. It is
      # written by a human-run command into the operator's own database; the
      # worker only ever reads it. There is no code path that writes one on the
      # worker's behalf, which is what makes "headless never becomes approval" a
      # structural property rather than a promise.
      DECISIONS = %w[tamoz worker decision].freeze

      # One decision per (thread, occurrence). The separator is a character that
      # cannot appear in either identifier, so two different pairs can never
      # collide into one key.
      def decision_key(thread_id, request_id)
        "#{thread_id}/#{request_id}"
      end

      def record_decision(thread_id, request_id, granted:)
        upsert(DECISIONS, decision_key(thread_id, request_id),
               {"granted" => granted, "recorded_at" => Time.now.utc.iso8601})
      end

      def decision_for(thread_id, request_id)
        entry = @adapter.store.get(DECISIONS, decision_key(thread_id, request_id))
        entry && entry.value["granted"]
      rescue StandardError
        nil
      end

      # The runtime store is versioned and refuses a blind second write. These
      # records are operator configuration that legitimately changes — a schedule
      # gets a new task, a thread a new profile — so writing one means replacing
      # the current version, not adding a first one.
      def upsert(namespace, key, value)
        @adapter.store.put(namespace, key, value,
                           if_version: @adapter.store.head_version(namespace, key))
      end

      def thread_profile(thread_id)
        entry = @adapter.store.get(THREAD_BINDINGS, thread_id)
        entry && entry.value["profile"]
      rescue StandardError
        nil
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
        canonical_session.capabilities.names(:action).sort
      rescue StandardError
        []
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
      def profile(profile_id)
        return nil if profile_id.nil?

        @profiles[profile_id] ||= begin
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
          memory_owner: engine && memory_owner
        )
      end
    end
  end
end

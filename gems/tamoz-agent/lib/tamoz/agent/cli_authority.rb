# frozen_string_literal: true

module Tamoz
  module Agent
    # What authority a durable session runs under, resolved at the CLI boundary.
    #
    # This is the most security-relevant code in the CLI, so it is one file with
    # one job. Three questions live here and nowhere else:
    #
    # - which operator profile, if any, this invocation loaded, and the operator
    #   confirmation that adoption requires
    # - what a session that ALREADY EXISTS is pinned to, read back from its own
    #   checkpoint rather than recomputed from the current profile file
    # - whether an operator-recorded transition may move it, at a turn boundary
    #
    # The asymmetry is the point. A new session takes its authority from the
    # loaded profile; an existing one replays what it was pinned to, so editing a
    # profile file cannot silently widen a session already in flight. Anything
    # that would change a running session's authority has to go through a
    # candidate transition the operator recorded explicitly.
    #
    # Every method here was PRIVATE on the CLI before the extraction and stays
    # private, so including this module does not widen CLI's surface.
    #
    # Pinned by test/agent_cli_profile_test.rb (the authority seam, 10 tests) and
    # test/agent_profile_machinery_test.rb.
    # rubocop:disable Metrics/ModuleLength -- one security boundary's complete
    # surface; every method inside is within the Q6 ceilings except the one that
    # names its own exception at the site.
    #
    # :reek:TooManyStatements — `adoption_confirmation` is one operator prompt,
    # `peek_session_record` one guarded read, `surface_dead_candidates` one
    # advisory; each is a single indivisible interaction.
    # :reek:LongParameterList :reek:ControlParameter — `resolve_session_authority`
    # takes the five facts the decision needs, and `boundary:` says whether this
    # call is AT a turn boundary. Only a boundary may consume a transition, so
    # that flag is the authority question, not a mode switch — see the note at
    # the method.
    # :reek:FeatureEnvy :reek:DuplicateMethodCall — `pinned_authority` interrogates
    # the replayed authority against the digest it must match; that comparison is
    # the check.
    module CLIAuthority
      private

      def load_operator_profile(options)
        requested = options[:profile]
        return nil unless requested

        path = Profile.resolve_path(profile: requested, env: @env)
        Profile.load(path, env: @env, confirm_adoption: adoption_confirmation(options))
      end

      def adoption_confirmation(options)
        lambda do |document|
          if options[:non_interactive]
            raise Profile::AdoptionError,
                  "profile #{document.profile_id} digest #{document.canonical_digest} requires " \
                  "operator adoption; run 'tamoz profile import' or activate it interactively"
          end

          @err.puts "Profile #{document.profile_id} is not activated."
          @err.puts "  digest: #{document.canonical_digest}"
          @err.puts "  canonical_root: #{document.canonical_root}"
          @err.print 'Activate this exact profile digest? [y/N] '
          @err.flush
          answer = @input.gets
          !!(answer && %w[y yes].include?(answer.strip.downcase))
        end
      end

      # §5.4/§5.5: decide, *before* any toolbox or session is built, which profile
      # is authority for this invocation. A profile edit never reaches an existing
      # thread by itself: either the thread replays the authority snapshot pinned
      # in its own checkpoint, or the operator has recorded an explicit candidate
      # transition that only a turn boundary may consume, or the command fails
      # closed. Nothing here can widen authority from repository or model content.
      #
      # DR-5 D2: at a turn boundary the candidate is consumed inside the registry's
      # ONE flocked check-and-mark RMW (`consume_if_candidate!`), marked with the
      # request id that will actually execute the turn (RC1). A losing concurrent
      # ask falls through to pinned replay below — never a typed terminal error for
      # a race. Dead candidates (stale on both ends, unconsumed) are surfaced as an
      # advisory; consumed entries never nag again (RC8).
      # Deliberately NOT split (CODING_STANDARD §4). This is ONE authority
      # decision with one early exit per outcome, and every branch needs the same
      # five facts: the record, the two digests, the profile id and the request
      # id. Splitting it produced helpers taking six loose parameters — the same
      # failure mode documented on Profile::TransitionRegistry#consume_if_candidate!,
      # where the split made it possible to reach the decision without its guard.
      # The method-length ceiling is diagnostic; this is the exception it allows.
      #
      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def resolve_session_authority(options, thread_id, profile, boundary:, request_id: nil)
        return nil unless profile

        record = peek_session_record(options, thread_id)
        return profile unless record

        loaded_digest = profile.canonical_digest
        loaded_id = profile.profile_id
        stored_id = record.fetch('profile_id')
        if stored_id == SessionRecords::LEGACY_PROFILE_ID
          raise Profile::AdoptionError,
                "session #{thread_id} predates trusted profiles; resume it without --profile"
        end
        unless stored_id == loaded_id
          raise Profile::AdoptionError,
                "session #{thread_id} belongs to profile #{stored_id.inspect}, not " \
                "#{loaded_id.inspect}; inspect it with 'tamoz show #{thread_id}' instead"
        end

        stored_digest = record.fetch('profile_digest')
        return profile if stored_digest == loaded_digest

        if boundary
          consumed = transition_registry.consume_if_candidate!(
            thread_id,
            profile_id: stored_id,
            from: stored_digest,
            to: loaded_digest,
            consumed_by: request_id
          )
          surface_dead_candidates(thread_id, stored_digest, loaded_digest)
          if consumed
            @err.puts "Applying operator transition for #{thread_id}: " \
                      "#{stored_digest} -> #{loaded_digest}."
            return profile
          end
        end

        pinned = pinned_authority(record, stored_digest)
        if pinned && Profile::AdoptionRegistry.new(env: @env).activated?(stored_id, stored_digest)
          @err.puts "Session #{thread_id} keeps its pinned authority #{stored_digest}; " \
                    "the edited profile #{loaded_digest} is not applied."
          return pinned
        end

        raise Profile::AdoptionError,
              "Session was created with profile #{stored_id} digest #{stored_digest}; " \
              "current profile digest is #{loaded_digest}. Run 'tamoz --profile " \
              "#{options[:profile]} profile activate --thread #{thread_id} --digest " \
              "#{stored_digest}' to keep the original authority, or --digest " \
              "#{loaded_digest} to record a candidate transition; inspect the " \
              "session read-only with 'tamoz show #{thread_id}'."
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # DR-5 D2 RC8: candidates for this thread that can no longer apply — stale on
      # both ends and unconsumed — are surfaced at the boundary instead of sitting
      # silently inert. Consumed entries are excluded (they are an audit trail, not
      # a nag). No pruning in v1; the operator re-records if the change should apply.
      def surface_dead_candidates(thread_id, stored_digest, loaded_digest)
        dead = transition_registry.dead_candidates(thread_id, stored_digest, loaded_digest)
        return if dead.empty?

        @err.puts "Session #{thread_id} has stale candidate transitions that can no longer apply:"
        dead.each do |entry|
          @err.puts "  #{entry.from_digest} -> #{entry.to_digest} (#{entry.reason})"
        end
        @err.puts "Record a fresh candidate with 'tamoz profile activate --thread #{thread_id} " \
                  "--digest <digest>' if the change should still take effect."
      end

      # The pinned snapshot is replayed through the full profile validator, so a
      # tampered checkpoint can only narrow the surface or fail closed (§5.4).
      def pinned_authority(record, stored_digest)
        snapshot = record['profile_authority']
        return nil unless snapshot

        pinned = Profile.from_authority(snapshot)
        unless pinned.canonical_digest == stored_digest
          raise Profile::ValidationError,
                "pinned authority digest #{pinned.canonical_digest} does not match the " \
                "session record digest #{stored_digest}"
        end

        pinned
      end

      # Read-only peek at the durable session record before the real session is
      # constructed. It never opens a writer and never mutates state.
      def peek_session_record(options, thread_id)
        require 'tamoz/sqlite'

        path = File.join(resolve_session_dir(options), "#{thread_id}.sqlite3")
        return nil unless File.file?(path)

        adapter = Tamoz::SQLite::Adapter.new(
          path:, limits: Tamoz::SQLite::Limits.new(lease_ttl: lease_ttl)
        )
        begin
          dummy_model = Object.new
          def dummy_model.generate(**) = '{}'
          toolbox = Tamoz::Agent::Toolbox.new(root: options[:root])
          session = Tamoz::Agent::Session.new(model: dummy_model, toolbox:, checkpointer: adapter)
          state = session.view(thread: thread_id).state
          state && state[:session]
        ensure
          adapter.close
        end
      end

      def transition_registry
        Profile::TransitionRegistry.new(env: @env)
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end

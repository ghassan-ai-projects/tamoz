# frozen_string_literal: true

module Tamoz
  module Agent
    # `tamoz profile` — the operator's view of trusted profiles.
    #
    # A profile is AUTHORITY: it pins the canonical root, the named checks, the
    # symbolic model roles, the budgets and the approval defaults a durable
    # session runs under. Nothing here grants that authority implicitly. The
    # verbs are deliberately split between reading a profile (`preview`, `list`,
    # `show`) and adopting one (`activate`, `import`), and adoption always ends
    # at an explicit operator confirmation of a specific digest.
    #
    # The rendering matters as much as the commands: the operator decides
    # adoption from what is printed, so `render_profile` must show every part of
    # the document that IS authority. Omitting a section would mean confirming a
    # digest whose contents the operator never saw.
    #
    # Pinned by test/agent_cli_profile_test.rb and test/agent_profile_test.rb.
    #
    # :reek:TooManyStatements — the renderers print one line per field and the
    # command entry points read their options then act; a method that emits seven
    # lines has seven statements, and there is no smaller unit than the list.
    # :reek:UtilityFunction — `parse_import!` is pure argv parsing; it belongs
    # beside the command it parses for, not on a collaborator of its own.
    # :reek:NestedIterators — OptionParser's DSL is a block of blocks; the nesting
    # is the library's shape, not ours.
    # :reek:DataClump — (options, argv) is the CLI's universal command signature,
    # the same pair every subcommand in every sibling module takes. It is a
    # convention, not an undiscovered object.
    # :reek:FeatureEnvy — the two verify_* guards interrogate the session record
    # and the loaded profile against each other. That comparison IS the check;
    # neither object can own it, because the whole point is that they might
    # disagree.
    # :reek:LongParameterList — `confirm_import!` shows the operator all four
    # facts they are being asked to confirm: the document, where it came from,
    # where it is going, and whether the run may prompt at all. Dropping any of
    # them would mean confirming with less than was promised.
    # rubocop:disable Metrics/ModuleLength -- one subcommand's complete surface:
    # five verbs, their option parsing, the two operator confirmations and the
    # adoption rendering. Splitting it would scatter one operator-facing command
    # across files to satisfy a line count; every METHOD inside is within the Q6
    # ceilings, which is the limit that describes readability here.
    module CLIProfileCommands
      # Every method here was PRIVATE on the CLI before the extraction, and stays
      # private, so including this module does not widen CLI's surface by a
      # single verb. `dispatch_subcommand` reaches `cmd_profile` with an implicit
      # receiver, which private permits.

      private

      def cmd_profile(options, argv)
        action = argv.shift
        case action
        when 'preview' then profile_preview(argv)
        when 'list' then profile_list(options)
        when 'show' then profile_show(argv)
        when 'import' then profile_import(options, argv)
        when 'activate' then profile_activate(options, argv)
        else
          raise OptionParser::InvalidArgument, "unknown profile action: #{action.inspect}"
        end
      end

      # §6.5: record an operator-confirmed candidate transition for one thread.
      # This writes only to operator-owned files; the durable session is never
      # touched, so in-flight authority cannot change here.
      def profile_activate(options, argv)
        thread_id, digest = parse_activation!(options, argv)
        profile = load_operator_profile(options)
        record = peek_session_record(options, thread_id)
        raise Profile::AdoptionError, "no durable session #{thread_id}" unless record

        stored_id = verify_session_profile!(record, profile, thread_id)
        stored_digest = record.fetch('profile_digest')
        verify_known_digest!(digest, stored_digest, profile)
        ensure_activated!(options, stored_id, digest)
        apply_activation(thread_id, stored_id, stored_digest, digest)
      end

      # All three of --thread, --digest and --profile are required, and the digest
      # must be a CANONICAL profile digest rather than any sha256.
      def parse_activation!(options, argv)
        thread_id = nil
        digest = nil
        OptionParser.new do |value|
          value.on('--thread THREAD', 'Durable thread id') { |entry| thread_id = entry }
          value.on('--digest DIGEST', 'Canonical profile digest to activate') { |entry| digest = entry }
        end.parse!(argv)
        raise OptionParser::MissingArgument, '--thread' if thread_id.to_s.empty?
        raise OptionParser::MissingArgument, '--digest' if digest.to_s.empty?
        raise OptionParser::MissingArgument, '--profile' if options[:profile].to_s.empty?

        validate_thread_id!(thread_id)
        unless Tamoz::Core.valid_digest?(digest)
          raise ArgumentError, '--digest must be a sha256: canonical profile digest'
        end

        [thread_id, digest]
      end

      # A transition only means anything within one profile family: a session that
      # predates trusted profiles has no path at all, and one belonging to another
      # profile is a different authority entirely.
      def verify_session_profile!(record, profile, thread_id)
        stored_id = record.fetch('profile_id')
        if stored_id == SessionRecords::LEGACY_PROFILE_ID
          raise Profile::AdoptionError,
                "session #{thread_id} predates trusted profiles and has no transition path"
        end
        loaded_id = profile.profile_id
        return stored_id if stored_id == loaded_id

        raise Profile::AdoptionError,
              "session #{thread_id} belongs to profile #{stored_id.inspect}, not " \
              "#{loaded_id.inspect}"
      end

      # Only two digests are meaningful for this session: the one it runs under
      # now, and the one the loaded profile has.
      def verify_known_digest!(digest, stored_digest, profile)
        loaded_digest = profile.canonical_digest
        return if [stored_digest, loaded_digest].include?(digest)

        raise Profile::AdoptionError,
              "digest #{digest} is neither the session digest #{stored_digest} nor the " \
              "loaded profile digest #{loaded_digest}"
      end

      def ensure_activated!(options, stored_id, digest)
        registry = Profile::AdoptionRegistry.new(env: @env)
        return if registry.activated?(stored_id, digest)

        confirm_digest_activation!(options, stored_id, digest)
        registry.activate(stored_id, digest)
      end

      # Activating the digest the session already runs under changes nothing;
      # anything else is a candidate for the NEXT turn boundary and never touches
      # the in-flight run.
      def apply_activation(thread_id, stored_id, stored_digest, digest)
        if digest == stored_digest
          @out.puts "Session #{thread_id} keeps profile #{stored_id} digest #{digest}."
          return 0
        end

        transition_registry.record(
          Profile::Transition.new(
            thread_id:, profile_id: stored_id, from_digest: stored_digest,
            to_digest: digest, reason: 'operator_activate'
          )
        )
        @out.puts "Candidate transition recorded for #{thread_id}: #{stored_digest} -> #{digest}."
        @out.puts "It takes effect at the next turn boundary; the in-flight session keeps #{stored_digest}."
        0
      end

      def confirm_digest_activation!(options, profile_id, digest)
        if options[:non_interactive]
          raise Profile::AdoptionError,
                "digest #{digest} is not activated for #{profile_id}; re-run interactively"
        end

        @err.puts "Digest #{digest} is not activated for profile #{profile_id}."
        @err.print 'Activate this exact profile digest? [y/N] '
        @err.flush
        answer = @input.gets
        return if answer && %w[y yes].include?(answer.strip.downcase)

        raise Profile::AdoptionError, 'activation not confirmed'
      end

      def profile_preview(argv)
        path = argv.shift
        raise OptionParser::MissingArgument, 'PATH' if path.to_s.empty?

        expanded = File.expand_path(File.path(path))
        document = Profile.preview(
          expanded,
          suggestion: Profile.suggestion_path?(expanded, env: @env),
          env: @env
        )
        render_profile(document)
        document.suggestion ? 3 : 0
      end

      def profile_list(options)
        entries = readable_profiles
        options[:json] ? render_profile_list_json(entries) : render_profile_list_human(entries)
        0
      end

      # A profile that no longer loads is skipped rather than fatal: one bad file
      # in the directory must not stop the operator seeing the rest.
      def readable_profiles
        directory = Profile.profiles_dir(env: @env)
        Dir.glob(File.join(directory, '*.yaml')).filter_map do |path|
          [File.basename(path, '.yaml'), Profile.preview(path)]
        rescue Profile::ProfileError
          nil
        end
      end

      def render_profile_list_json(entries)
        @out.puts JSON.generate(
          entries.map do |name, document|
            { 'file' => name, 'profile_id' => document.profile_id,
              'profile_version' => document.profile_version,
              'canonical_digest' => document.canonical_digest }
          end
        )
      end

      def render_profile_list_human(entries)
        entries.each do |name, document|
          @out.puts "#{name}: #{document.profile_id} #{document.profile_version} #{document.canonical_digest}"
        end
      end

      def profile_show(argv)
        id = argv.shift
        raise OptionParser::MissingArgument, 'PROFILE_ID' if id.to_s.empty?

        path = Profile.resolve_path(profile: id, env: @env)
        render_profile(Profile.preview(path))
        0
      end

      def profile_import(options, argv)
        force = parse_import!(argv)
        source = argv.shift
        raise OptionParser::MissingArgument, 'PATH' if source.to_s.empty?

        expanded = File.expand_path(File.path(source))
        captured = Profile.preview_source(
          expanded,
          suggestion: Profile.suggestion_path?(expanded, env: @env),
          env: @env
        )
        document = captured.document
        target = File.join(Profile.profiles_dir(env: @env), "#{document.profile_id}.yaml")
        if File.exist?(target) && !force
          raise Profile::AdoptionError, "#{target} already exists; use --force and confirm to replace it"
        end

        confirm_import!(options, document, expanded, target) unless force
        install_profile(captured, document, target)
      end

      def parse_import!(argv)
        force = false
        OptionParser.new do |value|
          value.on('--force', 'Overwrite an existing profile with the same id') { force = true }
        end.parse!(argv)
        force
      end

      # The operator is shown the id, the digest, and both paths before anything
      # is written, because this is the moment authority is granted.
      def confirm_import!(options, document, expanded, target)
        if options[:non_interactive]
          raise Profile::AdoptionError,
                'import requires operator confirmation; re-run interactively or pass --force'
        end

        @err.puts "Import #{document.profile_id} digest #{document.canonical_digest}"
        @err.puts "  from: #{expanded}"
        @err.puts "  to:   #{target}"
        @err.print 'Install and activate this exact profile? [y/N] '
        @err.flush
        answer = @input.gets
        return if answer && %w[y yes].include?(answer.strip.downcase)

        raise Profile::AdoptionError, 'import not confirmed'
      end

      # Install the validated bytes, created 0600 from the first byte written, so
      # neither a re-read of a repository-controlled source nor a window of loose
      # permissions can put content into the operator's profile directory that the
      # operator never saw and never confirmed.
      def install_profile(captured, document, target)
        directory = File.dirname(target)
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
        File.open(target, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |handle|
          handle.binmode
          handle.write(captured.bytes)
        end
        File.chmod(0o600, target)
        profile_id = document.profile_id
        digest = document.canonical_digest
        Profile::AdoptionRegistry.new(env: @env).activate(profile_id, digest)
        @out.puts "Imported #{profile_id} (#{digest})"
        0
      end

      # The operator decides adoption from this rendering, so it must show every
      # part of the profile that *is* authority. Omitting the checks meant an
      # operator confirmed an argv they had never been shown. Credential references
      # are rendered by env-var name only; a profile can never hold a secret value
      # (invariant 24), and this surface never resolves one.
      def render_profile(document)
        render_profile_identity(document)
        render_profile_checks(document)
        render_profile_model_roles(document)
        render_profile_policy(document)
      end

      def render_profile_identity(document)
        @out.puts "profile_id: #{document.profile_id}"
        @out.puts "profile_version: #{document.profile_version}"
        @out.puts "canonical_root: #{document.canonical_root}"
        @out.puts "canonical_digest: #{document.canonical_digest}"
        @out.puts "allow_changes: #{document.allow_changes?}"
        @out.puts "tools.allowed: #{document.tools_allowed.join(', ')}"
      end

      def render_profile_policy(document)
        policy = document.policy
        document.budgets.sort.each { |name, value| @out.puts "budgets.#{name}: #{value}" }
        @out.puts "policy.default_check_safety: #{policy.fetch('default_check_safety')}"
        @out.puts "policy.behavior_version: #{policy.fetch('behavior_version')}"
        @out.puts "high_risk: #{document.high_risk?}"
        @out.puts "suggestion: #{document.suggestion}"
      end

      def render_profile_checks(document)
        checks = document.checks
        @out.puts "checks: #{checks.empty? ? '(none)' : checks.length}"
        checks.sort.each do |name, check|
          check_argv = check.fetch('argv').map(&:inspect).join(' ')
          @out.puts "  check #{name} [#{check.fetch('safety')}]: #{check_argv}"
        end
      end

      def render_profile_model_roles(document)
        roles = document.model_roles
        @out.puts "model_roles: #{roles.empty? ? '(none)' : roles.length}"
        roles.sort.each do |name, role|
          reference = role['credential_ref']
          suffix = reference ? " credential_ref=#{reference.fetch('name')}" : ''
          @out.puts "  role #{name}: #{role.fetch('provider')}/#{role.fetch('model')}#{suffix}"
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end

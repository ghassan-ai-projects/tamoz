# frozen_string_literal: true

require 'fileutils'
require 'psych'
require 'time'

module Tamoz
  module Agent
    class Profile
      # Operator-side candidate transition registry (§5.4/§6.5). Lives beside the
      # adoption registry, outside any profile file and any repository, mode 0600,
      # and participates in no digest. Recording a candidate never touches session
      # state, so in-flight authority cannot be mutated by writing here.
      #
      # Every writer — operator `record` and the consuming boundary ask — does its
      # full-file read-modify-write inside ONE flocked critical section
      # (`with_registry_lock`), so concurrent record and consume cannot clobber
      # each other's writes and the candidate is consumed exactly once. flock
      # releases on fd close, so a killed writer never leaves a stale lock wedging
      # the registry.
      #
      # This class owns STORAGE and LOCKING. Whether a document read off disk may
      # be believed — including the v1/v2 codec — is TransitionDocument's question.
      #
      # :reek:TooManyMethods — the public surface is the registry's four verbs;
      # the rest are the locked write path, kept private and named.
      # :reek:RepeatedConditional — `File.exist?(@path)` guards the read and the
      # lock's permission check. Both are load-bearing and neither can be hoisted
      # out of its critical section.
      # :reek:MissingSafeMethod — `consume_if_candidate!` and `validate!` are
      # reported here because the smell is class-level. Both bangs are deliberate
      # and neither has a useful safe twin: there is no non-consuming consume, and
      # no predicate form of a raise-on-invalid contract.
      class TransitionRegistry
        REGISTRY_SCHEMA_VERSION = TransitionDocument::SCHEMA_VERSION
        LEGACY_REGISTRY_SCHEMA_VERSION = TransitionDocument::LEGACY_SCHEMA_VERSION
        REASON_PATTERN = /\A[a-z][a-z0-9_]{0,63}\z/
        THREAD_PATTERN = /\A[A-Za-z0-9_\-.]{1,64}\z/

        attr_reader :path

        # :reek:ControlParameter — `path:` is the injection seam the tests use;
        # production passes nil and takes the operator's configured location.
        def initialize(path: nil, env: ENV)
          @path = path || Profile.transitions_path(env:)
          freeze
        end

        # :reek:FeatureEnvy — a decoder over rows it does not own; the envy is the
        # job.
        def candidates(thread_id)
          thread = String(thread_id)
          document.fetch('transitions').fetch(thread, []).map do |entry|
            Transition.new(
              thread_id: thread,
              profile_id: entry.fetch('profile_id'),
              from_digest: entry.fetch('from_digest'),
              to_digest: entry.fetch('to_digest'),
              reason: entry.fetch('reason'),
              consumed_by: entry['consumed_by'],
              consumed_at: entry['consumed_at']
            )
          end
        end

        # A consumed entry is an audit record: it can never re-apply, so it is
        # never a candidate again.
        #
        # :reek:ControlParameter :reek:FeatureEnvy :reek:LongParameterList
        # :reek:DataClump — (profile_id, from, to) is the transition identity
        # triple, and it is spelled out at every call site on purpose: this is the
        # authority question, and a value object wrapping it would let two of the
        # three be defaulted or reordered silently.
        def candidate?(thread_id, profile_id:, from:, to:)
          candidates(thread_id).any? do |entry|
            !entry.consumed? &&
              entry.profile_id == profile_id && entry.from_digest == from && entry.to_digest == to
          end
        end

        # DR-5 D2 RC8: candidates that can no longer apply for this thread — the
        # session is past `from_digest` and the current profile is past
        # `to_digest` — are surfaced at the boundary instead of sitting silently
        # inert. Consumed entries are excluded so the advisory never fires on
        # every subsequent ask for the thread's life; no pruning in v1 (audit).
        #
        # :reek:ControlParameter :reek:FeatureEnvy
        def dead_candidates(thread_id, stored_digest, loaded_digest)
          candidates(thread_id).select do |entry|
            !entry.consumed? &&
              entry.from_digest != stored_digest &&
              entry.to_digest != loaded_digest
          end
        end

        # :reek:TooManyStatements — one locked read-modify-write; see
        # `consume_if_candidate!` for why this shape is deliberate.
        def record(transition)
          validate!(transition)
          with_registry_lock do
            thread = transition.thread_id
            current = document
            transitions = current.fetch('transitions')
            list = transitions.fetch(thread, [])
            entry = transition.to_h_document
            return transition if list.include?(entry)

            write_document(current.merge('transitions' => transitions.merge(thread => list + [entry])))
            transition
          end
        end

        # DR-5 D2 RC2: ONE flocked check-and-mark RMW. Returns the consumed
        # Transition when this writer won the race, nil when the entry is absent
        # or already consumed (a lost race falls through to pinned replay — never
        # a typed terminal error). The decision is made on the CURRENT file bytes
        # inside the lock, so no stale before-image can be consumed (no TOCTOU).
        #
        # Deliberately NOT split into named steps (CODING_STANDARD §4). Find,
        # guard, mark, write and return are one atomic decision taken against one
        # read of the file; splitting them produced helpers that took the identity
        # triple as loose parameters and made it possible to call the mark without
        # the guard. The method-length ceiling is diagnostic, and this is the
        # exception it allows for.
        #
        # :reek:TooManyStatements :reek:LongParameterList :reek:DataClump
        # :reek:ControlParameter — the identity triple selects the entry; that is
        # the query, not a hidden mode switch.
        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/BlockLength
        def consume_if_candidate!(thread_id, profile_id:, from:, to:, consumed_by:)
          raise ArgumentError, 'consumed_by is required to consume a candidate' if consumed_by.to_s.empty?

          thread = String(thread_id)
          burner = String(consumed_by)
          with_registry_lock do
            current = document
            transitions = current.fetch('transitions')
            list = transitions.fetch(thread, [])
            index = list.index do |entry|
              entry.fetch('profile_id') == profile_id &&
                entry.fetch('from_digest') == from &&
                entry.fetch('to_digest') == to
            end
            return nil unless index

            candidate = list.fetch(index)
            return nil if candidate.key?('consumed_by')

            consumed_at = Time.now.utc.iso8601
            updated_list = list.dup
            updated_list[index] = candidate.merge(
              'consumed_by' => burner, 'consumed_at' => consumed_at
            )
            write_document(current.merge('transitions' => transitions.merge(thread => updated_list)))
            Transition.new(
              thread_id: thread,
              profile_id: candidate.fetch('profile_id'),
              from_digest: candidate.fetch('from_digest'),
              to_digest: candidate.fetch('to_digest'),
              reason: candidate.fetch('reason'),
              consumed_by: burner,
              consumed_at:
            )
          end
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/BlockLength

        private

        # The registry's single write critical section. flock is advisory but the
        # only writers are the two paths through this class, so both serialize
        # here; flock releases when the descriptor closes (including process
        # death), so a killed writer can never leave the registry wedged.
        #
        # :reek:TooManyStatements — directory setup, lock acquisition, the
        # permission check and the release are one indivisible protocol.
        def with_registry_lock
          directory = File.dirname(@path)
          FileUtils.mkdir_p(directory, mode: 0o700)
          File.chmod(0o700, directory)
          File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            begin
              Profile.verify_permissions!(@path) if File.exist?(@path)
              yield
            ensure
              lock.flock(File::LOCK_UN)
            end
          end
        end

        # Every write bumps the file to schema_version 2 (the codec's only
        # migration step, stated): a v1 file that is recorded onto or consumed
        # from is upgraded in place; v1 files are never rewritten by a mere read.
        def write_document(document)
          File.write(@path, Psych.dump(document.merge('schema_version' => REGISTRY_SCHEMA_VERSION)))
          File.chmod(0o600, @path)
        end

        # :reek:TooManyStatements :reek:MissingSafeMethod — the bang is the
        # raise-on-invalid contract; there is no useful predicate twin.
        def validate!(transition)
          field_rules.each do |field, (pattern, noun)|
            value = transition.public_send(field)
            raise AdoptionError, "invalid #{noun} #{value.inspect}" unless pattern.match?(value)
          end

          [transition.from_digest, transition.to_digest].each do |digest|
            next if DIGEST_PATTERN.match?(digest)

            raise AdoptionError, "invalid transition digest #{digest.inspect}"
          end
        end

        # Built per call rather than held in a constant: PROFILE_ID_PATTERN and
        # DIGEST_PATTERN belong to Profile, which loads AFTER this file, so a
        # constant here would evaluate them before they exist. Insertion order is
        # the checking order, and each noun is the exact word the message uses.
        #
        # :reek:UtilityFunction — a lookup table, not behaviour.
        def field_rules
          {
            thread_id: [THREAD_PATTERN, 'thread id'],
            profile_id: [PROFILE_ID_PATTERN, 'profile id'],
            reason: [REASON_PATTERN, 'transition reason']
          }
        end

        # Returns the empty document when no registry exists yet, so callers never
        # branch on the file's existence themselves.
        #
        # :reek:TooManyStatements — read, verify, parse, validate, normalize is
        # the whole of the read path and is not meaningfully divisible.
        # :reek:UncommunicativeVariableName — rubocop's
        # Naming/RescuedExceptionsVariableName requires `e`; the toolchain wins
        # over reek's preference here (CODING_STANDARD §1).
        def document
          return TransitionDocument.empty unless File.exist?(@path)

          Profile.verify_permissions!(@path)
          data = Psych.safe_load(
            File.binread(@path), permitted_classes: [], permitted_symbols: [], aliases: false
          )
          raise AdoptionError, "#{@path}: transition registry is invalid" unless TransitionDocument.new(data).valid?

          Profile.normalize_keys(data)
        rescue Psych::Exception => e
          raise AdoptionError, "#{@path}: transition registry is unreadable: #{e.message}"
        end
      end
    end
  end
end

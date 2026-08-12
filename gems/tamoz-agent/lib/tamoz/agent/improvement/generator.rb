# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Agent
    module Improvement
      # P12-I1 (plan §7): generate AT MOST ONE bounded heuristic candidate from
      # verified trajectories.
      #
      # Two properties matter more than the generation itself:
      #
      # 1. **Holdout isolation is a capability restriction (plan §7 C7/P3).**
      #    The generator reads trajectories ONLY through a `Tamoz::Tools::Toolbox`
      #    whose root is the train partition. The protected holdout corpus and
      #    the evaluator's output live OUTSIDE that root, so an attempted read
      #    is refused by `Toolbox#resolve`'s root confinement
      #    (`ToolPolicyError`) — the same OS/capability boundary P11-W's
      #    `MemoryHoldout` asserts against, not a convention this class checks
      #    on itself. The constructor additionally REFUSES to exist if the grant
      #    it was handed overlaps a protected partition, so an
      #    over-broad grant is caught before a single trajectory is read.
      #
      # 2. **The generator can never activate anything.** It holds no Store, no
      #    `TransitionRegistry`, and no session. `generate` returns a value.
      #    Plan §7: "never activate live prompt/code changes during the
      #    generating task" is therefore structural, not procedural.
      class Generator
        # Plan §7: "at most one bounded planning/routing/verification heuristic
        # candidate". Enforced, not documented.
        ONE_CANDIDATE_LIMIT = 1
        # Evidence floor: below this a candidate is not generated at all, so a
        # heuristic can never be promoted on one lucky trajectory.
        MIN_TRIALS = 3
        MIN_SUPPORT = 3
        MIN_CONFIDENCE = 0.8
        MAX_TRAJECTORIES = 256
        PRINCIPAL_DOMAIN = "tamoz.agent.improvement.generator.v1\n"

        attr_reader :principal, :toolbox

        # @param toolbox   the generator's ONLY capability: rooted at the train
        #                  partition, read-only (`allow_changes: false`).
        # @param principal the generating principal's identity — recorded in the
        #                  candidate and checked against the evaluator's.
        # @param protected_paths absolute paths that must NOT be inside the
        #                  grant: the holdout corpus and the evaluator output.
        def initialize(toolbox:, principal:, protected_paths: [])
          if toolbox.action_capable?
            raise HoldoutIsolationError,
                  "the trajectory generator must not hold a mutation capability"
          end
          @toolbox = toolbox
          @principal = String(principal)
          raise ImprovementPolicyError, "generator requires a principal" if @principal.empty?

          @protected_paths = Array(protected_paths).map { |path| File.realpath(String(path)) }
          assert_isolated!
          @generated = 0
        end

        # Construction-time refusal (plan §7 C7/P3). The runtime enforcement is
        # the toolbox root; this makes an over-broad GRANT impossible rather
        # than merely unused.
        def assert_isolated!
          root = @toolbox.root.to_s
          prefix = "#{root}#{File::SEPARATOR}"
          @protected_paths.each do |path|
            next unless path == root || path.start_with?(prefix)

            raise HoldoutIsolationError,
                  "generator grant #{root} contains the protected partition #{path}; " \
                  "the holdout corpus and evaluator output must lie outside the grant"
          end
          true
        end

        # Stable identity of what generated the candidate: the principal plus
        # the capability surface it held. A generator with a different grant is
        # a different generator, and the provenance records which one ran.
        def digest
          Tamoz::Core.digest(
            PRINCIPAL_DOMAIN,
            [@principal, @toolbox.catalog_digest, MIN_TRIALS, MIN_SUPPORT, MIN_CONFIDENCE]
          )
        end

        # Read one trajectory through the CAPABILITY. `relative_path` is
        # relative to the grant root; anything outside it raises
        # `Tamoz::Tools::ToolPolicyError` from the toolbox, which is the point.
        def read_trajectory(relative_path)
          rendered = @toolbox.execute("read_file", {"path" => String(relative_path)})
          body = rendered.split("content:\n", 2).last
          JSON.parse(String(body))
        end

        # Generate the single candidate. Deterministic and provider-free: the
        # heuristic is the most-supported ordered (precursor, subject) tool pair
        # over VERIFIED trajectories only, and it is emitted only if it clears
        # the support/confidence floor. Returns `nil` when the evidence does not
        # support any heuristic — an empty result is the honest outcome, not a
        # weaker heuristic.
        def generate(trajectory_paths:)
          if @generated >= ONE_CANDIDATE_LIMIT
            raise ImprovementPolicyError,
                  "the generator may produce at most #{ONE_CANDIDATE_LIMIT} candidate per phase"
          end
          paths = Array(trajectory_paths)
          if paths.length > MAX_TRAJECTORIES
            raise ImprovementPolicyError, "trajectory corpus exceeds #{MAX_TRAJECTORIES} entries"
          end

          trajectories = paths.sort.map { |path| read_trajectory(path) }
          verified = trajectories.select { |entry| entry.is_a?(Hash) && entry["verified"] == true }
          return nil if verified.empty?

          best = rank(verified)
          return nil unless best

          pair, support = best
          precursor, subject = pair
          trials = verified.count { |entry| uses?(entry, subject) }
          return nil if trials < MIN_TRIALS || support < MIN_SUPPORT

          confidence = support.to_f / trials
          return nil if confidence < MIN_CONFIDENCE

          @generated += 1
          Heuristic.new(
            heuristic_id: "heuristic.#{precursor}-before-#{subject}",
            surface: :planning,
            precursor_tool: precursor,
            subject_tool: subject,
            support:,
            trials:,
            confidence: (confidence * 10_000).round / 10_000.0,
            statement:
              "When a plan step uses #{subject} on a path, first plan a #{precursor} step on that " \
              "same path. Observed in #{support} of #{trials} verified trajectories.",
            generator_principal: @principal
          ).assert_bounded!
        end

        # The verified source trajectories in provenance shape. Only the
        # trajectory IDENTITY and a content digest cross into the provenance —
        # never trajectory bodies, and never anything read from outside the
        # grant, because nothing outside the grant is readable.
        def source_refs(trajectory_paths:)
          Array(trajectory_paths).sort.filter_map do |path|
            entry = read_trajectory(path)
            next unless entry.is_a?(Hash) && entry["verified"] == true

            {
              "trajectory_id" => entry.fetch("trajectory_id"),
              "digest" => Tamoz::Core.digest(PRINCIPAL_DOMAIN, entry),
              "partition" => "train",
              "verified" => true
            }
          end
        end

        private

        def uses?(trajectory, tool)
          Array(trajectory["steps"]).any? { |step| step.is_a?(Hash) && step["tool"] == tool }
        end

        # Count ordered (precursor, subject) pairs where the precursor is a
        # read-only tool acting on the same path earlier in the trajectory.
        # Ties break on the sorted pair name so the generator is deterministic
        # regardless of hash ordering.
        def rank(verified)
          counts = Hash.new(0)
          verified.each do |trajectory|
            pairs_in(trajectory).each { |pair| counts[pair] += 1 }
          end
          return nil if counts.empty?

          counts.max_by { |pair, count| [count, -pair.join("\0").bytes.sum, pair.join("\0")] }
                &.then { |pair, count| [pair, count] }
        end

        def pairs_in(trajectory)
          steps = Array(trajectory["steps"]).select { |step| step.is_a?(Hash) }
          found = []
          steps.each_with_index do |step, index|
            target = step.dig("arguments", "path")
            next unless target.is_a?(String)

            steps[0...index].each do |earlier|
              next unless earlier.dig("arguments", "path") == target
              next unless Heuristic::INSERTABLE_TOOLS.include?(String(earlier["tool"]))
              next if earlier["tool"] == step["tool"]

              found << [String(earlier["tool"]), String(step["tool"])]
            end
          end
          found.uniq
        end
      end
    end
  end
end

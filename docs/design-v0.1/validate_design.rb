# frozen_string_literal: true

# Stdlib-only consistency checks for the design package.

root = File.expand_path(__dir__)
markdown_files = Dir[File.join(root, "*.md")].sort
failures = []

required_files = %w[
  README.md
  GOAL.md
  REVIEW.md
  ARCHITECTURE.md
  RUBY_TRANSLATION.md
  CORE_DESIGN.md
  GRAPH_DESIGN.md
  PERSISTENCE_DESIGN.md
  CHAIN_DESIGN.md
  AGENT_DESIGN.md
  TAMOZ_AGENT_DESIGN.md
  MEMORY_DESIGN.md
  SELF_HEALING_DESIGN.md
  MCP_DESIGN.md
  SCHEDULER_DESIGN.md
  SKILLS_DESIGN.md
  STREAMING_INPUT_DESIGN.md
  INVARIANTS.md
  IMPLEMENTATION_PLAN.md
  EVALUATION_DESIGN.md
  EVALS_DESIGN.md
  DECISIONS.md
].freeze

required_files.each do |name|
  path = File.join(root, name)
  failures << "missing required file: #{name}" unless File.file?(path)
end

markdown_files.each do |path|
  text = File.read(path, encoding: Encoding::UTF_8)
  fence_count = text.lines.count { |line| line.start_with?("```") }
  failures << "#{File.basename(path)}: unbalanced fenced code blocks" unless fence_count.even?

  in_fence = false
  h1_count = text.lines.count do |line|
    if line.start_with?("```")
      in_fence = !in_fence
      false
    else
      !in_fence && line.start_with?("# ")
    end
  end
  failures << "#{File.basename(path)}: expected one H1, found #{h1_count}" unless h1_count == 1

  text.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten.each do |target|
    next if target.start_with?("http://", "https://", "#", "mailto:")

    relative = target.split("#", 2).first
    next if relative.nil? || relative.empty?

    resolved = File.expand_path(relative, File.dirname(path))
    failures << "#{File.basename(path)}: broken local link #{target}" unless File.exist?(resolved)
  end
end

invariants = File.read(File.join(root, "INVARIANTS.md"), encoding: Encoding::UTF_8)
numbers = invariants.scan(/^\| (\d+) \| \*\*/).flatten.map(&:to_i)
expected_numbers = (1..55).to_a
failures << "invariants must be numbered 1..55; found #{numbers.inspect}" unless numbers == expected_numbers

conformance = invariants.split("## Required conformance tests", 2).last.to_s
covered_numbers = conformance.scan(/^\| ([\d, ]+) \|/).flatten
                             .flat_map { |cell| cell.scan(/\d+/).map(&:to_i) }
                             .uniq
                             .sort
missing_coverage = expected_numbers - covered_numbers
extra_coverage = covered_numbers - expected_numbers
unless missing_coverage.empty? && extra_coverage.empty?
  failures << "conformance coverage mismatch: missing #{missing_coverage.inspect}, " \
              "extra #{extra_coverage.inspect}"
end

all_text = markdown_files.map do |path|
  [File.basename(path), File.read(path, encoding: Encoding::UTF_8)]
end
forbidden = {
  "All 18 invariants" => "stale invariant count",
  "The 18 invariants" => "stale invariant count",
  "all 24 invariants" => "stale invariant count",
  "The 24 invariants" => "stale invariant count",
  "24 clauses" => "stale invariant count",
  "24-clause" => "stale invariant count",
  "Twenty-four clauses" => "stale invariant count",
  "all 28 invariants" => "stale invariant count",
  "The 28 invariants" => "stale invariant count",
  "28 clauses" => "stale invariant count",
  "28-clause" => "stale invariant count",
  "Twenty-eight clauses" => "stale invariant count",
  "Ruby 3.2 floor" => "EOL Ruby floor",
  "Six gems, one namespace" => "stale package count",
  "UUIDv7-style: unique AND monotonically sortable" => "UUID ordering used as sequence",
  "no duplicated side effects" => "impossible exactly-once guarantee",
  "no double execution" => "impossible exactly-once guarantee",
  "StreamPart#ns" => "stale StreamPart field",
  "subgraph with private checkpointer" => "stale subgraph persistence model",
  "a >> b >> c" => "stale context-losing composition claim",
  "Loom" => "retired framework name",
  "loom" => "retired framework name",
  "Weaver" => "retired reference-agent name",
  "weaver" => "retired reference-agent name"
}.freeze

all_text.each do |name, text|
  forbidden.each do |phrase, reason|
    failures << "#{name}: #{reason}: #{phrase.inspect}" if text.include?(phrase)
  end
end

readme = File.read(File.join(root, "README.md"), encoding: Encoding::UTF_8)
failures << "README.md: canonical framework title is missing" unless readme.start_with?("# Tamoz ")
required_files.reject { |name| name == "README.md" }.each do |name|
  failures << "README.md does not reference #{name}" unless readme.include?("(#{name})")
end

agent_design = File.read(File.join(root, "TAMOZ_AGENT_DESIGN.md"), encoding: Encoding::UTF_8)
unless agent_design.start_with?("# Tamoz Agent ")
  failures << "TAMOZ_AGENT_DESIGN.md: canonical reference-agent title is missing"
end

decisions = File.read(File.join(root, "DECISIONS.md"), encoding: Encoding::UTF_8)
adr_numbers = decisions.scan(/^### ADR-(\d{3}) /).flatten.map(&:to_i)
expected_adrs = (1..40).to_a
failures << "ADRs must be numbered 001..040; found #{adr_numbers.inspect}" unless adr_numbers == expected_adrs

required_terms = {
  "ARCHITECTURE.md" => %w[effect fence definition_digest tamoz-evals production],
  "PERSISTENCE_DESIGN.md" => %w[
    attempt_token request_id behavior_version attempt_id enqueue_request enqueue_sequence
    tombstone_thread
  ],
  "GRAPH_DESIGN.md" => %w[request_id effect_unknown attempt_id activation_checkpoint_id],
  "AGENT_DESIGN.md" => ["effect_unknown", "cache_epoch", "plan_reviews", "behavior_version",
                        "discovery plan", "action plan"],
  "TAMOZ_AGENT_DESIGN.md" => %w[accepted_plan self-improvement],
  "EVALS_DESIGN.md" => %w[protected holdout behavior_version insufficient_evidence subject sandbox],
  "MEMORY_DESIGN.md" => %w[Experience Knowledge Wisdom authorize],
  "SELF_HEALING_DESIGN.md" => %w[typed preflight compensation circuit_open],
  "MCP_DESIGN.md" => %w[CapabilityDescriptor protocol_profile elicitation effect],
  "SCHEDULER_DESIGN.md" => %w[occurrence misfire_policy overlap_policy request_id],
  "SKILLS_DESIGN.md" => %w[SKILL.md tree_digest allowed-tools progressive],
  "STREAMING_INPUT_DESIGN.md" => [
    "ChannelDescriptor", "SituationSnapshot", "watermark", "backpressure", "ActionIntent",
    "interlocks", "effect_unknown", "minimum Situation completeness", "partitioner algorithm"
  ]
}.freeze

required_terms.each do |name, terms|
  text = File.read(File.join(root, name), encoding: Encoding::UTF_8)
  terms.each do |term|
    failures << "#{name}: missing required contract term #{term.inspect}" unless text.include?(term)
  end
end

if failures.empty?
  puts "design validation passed (#{markdown_files.length} documents, 55 invariants, 40 ADRs)"
  exit 0
end

warn failures.join("\n")
exit 1

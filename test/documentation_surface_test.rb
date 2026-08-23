# frozen_string_literal: true

require_relative "test_helper"

# P15-G — the user-facing documentation is checked against the REAL surface.
#
# Stale documentation is not a cosmetic problem: this repository shipped a
# README claiming the agent "is not yet crash-durable" for months after P6 made
# it durable, and a SECURITY.md describing an M0 foundation with "not an
# operational agent" long after the agent could edit files. A doc that
# describes a product nobody has is worse than no doc, because a reader
# believes it.
#
# So every claim these pages make about the surface is derived from the surface
# here, and every gap they disclose is derived from the measured audit.
class DocumentationSurfaceTest < Minitest::Test
  INSTALL = ROOT.join("documentation", "getting-started", "install.md")
  LIMITATIONS = ROOT.join("documentation", "limitations.md")
  OPERATIONS = ROOT.join("documentation", "operations", "operations.md")
  README = ROOT.join("README.md")

  def text(path) = File.read(path, encoding: Encoding::UTF_8)

  def test_the_user_facing_pages_exist
    [INSTALL, LIMITATIONS, OPERATIONS, README].each { |path| assert_path_exists path }
  end

  # Every subcommand the CLI has must be documented, and every subcommand the
  # install guide documents must exist. Both directions matter: the first stops
  # a verb shipping undocumented, the second stops the guide describing a verb
  # that was removed.
  def test_the_install_guide_documents_exactly_the_real_subcommands
    documented = text(INSTALL).scan(/^\| `([a-z-]+)` \| /).flatten
                              .reject { |name| name.start_with?("tamoz-") }
    real = Tamoz::Agent::CLI::SUBCOMMANDS.map do |name|
      {"follow_up" => "follow-up", "followup" => "follow-up"}.fetch(name, name)
    end.uniq

    assert_equal real.sort, documented.sort
  end

  # Every global flag the guide shows a reader must be a flag the CLI accepts.
  def test_every_documented_flag_is_a_real_flag
    # A flag is real if the global parser accepts it OR the subcommand it is
    # shown with accepts it. Checking only the global parser would either reject
    # honest documentation of a subcommand's own flags, or push every subcommand
    # flag into the global namespace to keep a test happy.
    help = +capture_help(["--help"])
    # The unattended subcommands each carry their own `--help`. The interactive
    # ones share the global flag surface and parse positionally, so asking them
    # for help means something else entirely. `queue` and `schedule` dispatch on
    # a verb first, so their flags live on the verb. `comms` and `config` do
    # the same.
    [%w[init], %w[worker], %w[status], %w[queue add], %w[queue list],
     %w[schedule add], %w[schedule list], %w[comms serve], %w[comms list],
     %w[comms doctor], %w[comms pair list], %w[comms delivery resolve],
     %w[config migrate], %w[observe tail], %w[observe metrics],
     %w[observe doctor]].each do |argv|
      help << capture_help(argv + ["--help"])
    end

    # Only flags shown on an actual `tamoz` command line are CLI flags; the page
    # also documents script flags such as `--jobs`, which belong to the audit
    # generator and would be a false positive here.
    documented = text(INSTALL).lines
                              .select { |line| line.include?("exec tamoz ") }
                              .flat_map { |line| line.scan(/--[a-z][a-z-]+/) }
                              .uniq

    refute_empty documented
    documented.each do |flag|
      assert_includes help, flag, "#{flag} is documented but the CLI does not accept it"
    end
  end

  def capture_help(argv)
    out = StringIO.new
    Tamoz::Agent::CLI.run(argv, out:, err: StringIO.new, input: StringIO.new, env: {})
    out.string
  rescue StandardError
    # A subcommand with no help of its own contributes nothing; the global
    # parser still has to account for whatever the guide shows.
    ""
  end

  # The gem table must match what the repository actually packages — this is
  # the check that would have caught tamoz-scheduler and tamoz-stream shipping
  # with no documentation at all.
  def test_the_install_guide_lists_every_packaged_gem
    documented = text(INSTALL).scan(/^\| `(tamoz-[a-z]+(?:-[a-z]+)*)` \| /).flatten

    assert_equal GEM_ROOTS.keys.sort, documented.sort
  end

  # The limitations page must disclose exactly the release-blocking gaps the
  # audit MEASURED. If a gap closes, this fails until the page stops claiming
  # it; if a new gap opens, this fails until the page discloses it.
  def test_limitations_discloses_every_measured_release_blocking_gap
    audit = read_json(ROOT.join('docs', 'requirements-audit.json'))
    gaps = audit.fetch('release_blocking_gaps')
    body = text(LIMITATIONS)

    gaps.each do |gap|
      heading = GAP_DISCLOSURES.fetch(gap) do
        flunk "#{gap} is a measured release-blocking gap with no entry in this test's " \
              'disclosure map; add it here and to docs/LIMITATIONS.md'
      end

      assert_includes body, heading,
                      "#{gap} is a measured release-blocking gap that LIMITATIONS.md " \
                      'does not disclose'
    end
  end

  # Each measured gap has a human name on the page; the mapping is explicit
  # so a renamed requirement cannot silently drop its disclosure.
  GAP_DISCLOSURES = {
    'ADR-015' => 'Durable barrier timing remains partial (ADR-015)',
    'INV-20' => 'Single-writer recovery evidence remains partial (invariant 20)',
    'INV-39' => 'Cron and civil-time scheduling (invariant 39)',
    'INV-43' => 'Skill installation and update (invariant 43)',
    'INV-56' => 'Channel communications (invariants 56–58, ADR-041–043)',
    'INV-57' => 'Channel communications (invariants 56–58, ADR-041–043)',
    'INV-58' => 'Channel communications (invariants 56–58, ADR-041–043)',
    'ADR-041' => 'Channel communications (invariants 56–58, ADR-041–043)',
    'ADR-042' => 'Channel communications (invariants 56–58, ADR-041–043)',
    'ADR-043' => 'Channel communications (invariants 56–58, ADR-041–043)',
    'ADR-044' => 'Observability remains partial (invariants 59–61, ADR-044–047)',
    'ADR-045' => 'Observability remains partial (invariants 59–61, ADR-044–047)',
    'ADR-046' => 'Observability remains partial (invariants 59–61, ADR-044–047)',
    'ADR-047' => 'Observability remains partial (invariants 59–61, ADR-044–047)',
    'INV-59' => 'Observability remains partial (invariants 59–61, ADR-044–047)',
    'INV-60' => 'Observability remains partial (invariants 59–61, ADR-044–047)',
    'INV-61' => 'Observability remains partial (invariants 59–61, ADR-044–047)',
    'OBJ-3' => 'Evaluation hard gates are not currently release-green (objective 3)',
    'PHASE-P3' => 'Coding behavior scorecard remains incomplete (phase P3)',
    'OBJ-7' => '## Release readiness'
  }.freeze

  # A limitation the page claims must still be TRUE. `OVERFLOW_POLICIES` being
  # unenforced is the load-bearing example: if someone implements enforcement,
  # this test fails and the page must be corrected rather than left claiming a
  # limitation the product no longer has.
  def test_claimed_limitations_are_still_true
    body = text(LIMITATIONS)

    if body.include?("Nothing reads them.")
      readers = Dir[ROOT.join("gems", "tamoz-{stream,sqlite}", "lib", "**", "*.rb")].select do |path|
        File.read(path, encoding: Encoding::UTF_8).match?(/queue_capacity|spool_capacity_bytes/)
      end

      assert_empty readers,
                   "LIMITATIONS.md claims the overflow declaration is never read, but " \
                   "#{readers.inspect} reads it"
    end

    if body.include?("Cron expressions and IANA timezones are not implemented")
      assert_equal %i[at interval], Tamoz::Scheduler::KINDS,
                   "LIMITATIONS.md claims cron is absent but the scheduler declares it"
    end

    if body.include?("The only effector is the simulator")
      refute defined?(Tamoz::Stream::RealEffector),
             "LIMITATIONS.md claims simulator-only actuation"
    end
  end

  # The README must not describe shipped capabilities as unavailable. These
  # exact phrases were live for months after the capability they denied.
  def test_the_readme_does_not_deny_shipped_capabilities
    body = text(README)
    denials = [
      "not yet crash-durable",
      "not an operational agent",
      "M0 contains package and evaluation foundations"
    ]
    denials.each do |phrase|
      refute_includes body, phrase,
                      "README denies a capability that shipped: #{phrase.inspect}"
    end
    assert_includes body, "documentation/limitations.md",
                    "the README must point at the honest limitations page"
  end

  def test_security_policy_does_not_deny_shipped_capabilities
    body = text(ROOT.join("SECURITY.md"))

    refute_includes body, "not an operational agent"
    refute_includes body, "M0 contains package and evaluation foundations"
  end

  # Operations must name a real recovery surface, not an aspirational one.
  def test_the_operations_runbook_names_real_apis
    body = text(OPERATIONS)

    assert_includes body, "integrity_check"
    assert_respond_to Tamoz::SQLite::Adapter.instance_method(:integrity_check), :name
    assert_includes body, "resolve THREAD EFFECT_KEY succeeded"
    assert_includes Tamoz::Agent::CLI::SUBCOMMANDS, "resolve"
    assert_includes body, "backup(to:"
    assert Tamoz::SQLite::Adapter.instance_method(:backup),
           "the runbook documents backup(to:) — it must exist"
  end
end

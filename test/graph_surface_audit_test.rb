# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# P18 (H5/C8) — audit accuracy. The Coverage + manifest-probe table
# regenerates by running the named product tests and reconciles every graph
# entry in `docs/public-api.json`; divergence raises AuditMismatchError.
#
# This test runs the generator and asserts it produces a table (deterministic
# regeneration). The generator is the audit's executable spec.
class GraphSurfaceAuditTest < Minitest::Test
  AUDIT_PATH = ROOT.join("docs", "GRAPH_SURFACE_AUDIT.md")

  def run_generator(*arguments)
    script = ROOT.join("script", "generate_graph_surface_audit")
    Open3.capture3(
      RbConfig.ruby, script.to_s, *arguments, chdir: ROOT.to_s
    )
  end

  def test_audit_generator_regenerates_the_table
    stdout, stderr, status = run_generator
    assert status.success?, "audit generator failed: #{stderr.to_s.lines.last(6).join}"

    assert_match(/wrote .*GRAPH_SURFACE_AUDIT\.md \(\d+ entries\)/, stdout)
    # The generator confirms the inventory and rewrites it only when the bytes
    # would change. Re-stamping on every run made `rake ci` dirty the worktree,
    # which P15 §12 counts as a release stopper.
    assert_match(%r{docs/public-api\.json (confirmed unchanged|rewrote)}, stdout)
    assert_empty(
      Open3.capture2("git", "status", "--porcelain", "docs/public-api.json", chdir: ROOT.to_s).first,
      "running the audit generator must leave docs/public-api.json unchanged"
    )

    audit = File.read(AUDIT_PATH)
    # The table reconciles every graph manifest entry: 27 entries, no
    # manifest_unresolved rows (the audit is a measured, honest inventory).
    assert_includes audit, "| Entry | Measured | Recommendation | Constant |"
    refute_includes audit, "manifest_unresolved",
                    "every graph manifest entry must resolve (C8)"
  end

  def test_graph_is_documented_as_the_agent_runtime
    # The C2 source finding: the graph gem IS the agent runtime. The audit
    # must show the runtime-critical surface as product-executed.
    audit = File.read(AUDIT_PATH)
    %w[Tamoz::Graph::Compiled Tamoz::Graph::Definition Tamoz::Graph::Task].each do |entry|
      row = audit.lines.find { |line| line.include?(entry) }
      assert row, "missing audit row for #{entry}"
      assert_includes row, "product_method_executed"
    end
  end

  def test_module_functions_are_measured_as_executed
    # The module-function blind spot (critic finding F2): Coverage records
    # `Tamoz.graph` as "#<Class:Tamoz>#graph"; the audit must normalize the
    # singleton-class signature and credit the module functions that the
    # product actually executed (agent_session/agent_runtime call them).
    audit = File.read(AUDIT_PATH)
    %w[Tamoz.graph Tamoz.interrupt].each do |entry|
      row = audit.lines.find { |line| line.include?("`#{entry}`") }
      assert row, "missing audit row for #{entry}"
      assert_includes row, "product_method_executed"
    end
    # Honest negative: the five `Reducers.*` reducers were NOT executed by the
    # product tests (only the internal `Reducers.resolve` ran). Class-only
    # matching would over-credit them; method-level matching must not.
    %w[Tamoz::Reducers.append Tamoz::Reducers.max Tamoz::Reducers.merge
       Tamoz::Reducers.min Tamoz::Reducers.union].each do |entry|
      row = audit.lines.find { |line| line.include?("`#{entry}`") }
      assert row, "missing audit row for #{entry}"
      assert_includes row, "manifest_resolved_only"
    end
  end

  def test_divergence_raises_audit_mismatch_error
    # The failure model (H5/§6): a committed table that disagrees with the
    # regeneration raises AuditMismatchError instead of silently overwriting.
    original = File.read(AUDIT_PATH)
    begin
      File.write(AUDIT_PATH, original.sub("| Entry |", "| ENTRY |"))
      stdout, stderr, status = run_generator
      refute status.success?, "divergent audit must fail: #{stdout}"
      assert_includes stderr, "AuditMismatchError"
      assert_includes stderr, "--accept"
    ensure
      File.write(AUDIT_PATH, original)
    end
    # The restore is byte-identical, so the plain regeneration still passes.
    stdout, stderr, status = run_generator
    assert status.success?, "restored audit must regenerate: #{stderr}"
  end
end

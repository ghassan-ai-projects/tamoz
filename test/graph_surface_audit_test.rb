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
  def test_audit_generator_regenerates_the_table
    script = ROOT.join("script", "generate_graph_surface_audit")
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, script.to_s, chdir: ROOT.to_s
    )
    assert status.success?, "audit generator failed: #{stderr.to_s.lines.last(6).join}"

    assert_match(/wrote .*GRAPH_SURFACE_AUDIT\.md \(\d+ entries\)/, stdout)
    assert_match(/regenerated docs\/public-api\.json/, stdout)

    audit = File.read(ROOT.join("docs", "GRAPH_SURFACE_AUDIT.md"))
    # The table reconciles every graph manifest entry: 27 entries, no
    # manifest_unresolved rows (the audit is a measured, honest inventory).
    assert_includes audit, "| Entry | Measured | Constant |"
    refute_includes audit, "manifest_unresolved",
                    "every graph manifest entry must resolve (C8)"
  end

  def test_graph_is_documented_as_the_agent_runtime
    # The C2 source finding: the graph gem IS the agent runtime. The audit
    # must show the runtime-critical surface as product-executed.
    audit = File.read(ROOT.join("docs", "GRAPH_SURFACE_AUDIT.md"))
    %w[Tamoz::Graph::Compiled Tamoz::Graph::Definition Tamoz::Graph::Task].each do |entry|
      row = audit.lines.find { |line| line.include?(entry) }
      assert row, "missing audit row for #{entry}"
      assert_includes row, "product_method_executed"
    end
  end
end

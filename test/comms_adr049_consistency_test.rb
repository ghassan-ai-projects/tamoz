# frozen_string_literal: true

require_relative 'test_helper'
require 'yaml'

# PLAN_ADR049 Phase 0 exit — a CI/doc consistency check: ADR-049's status,
# the ADR-043 retirement in the comms design, the flow contract's §2
# resolution, and the bar's C1 grade must agree with each other and with the
# code that implements them. If any of these drift, the authority record no
# longer matches the graded instrument.
class CommsAdr049ConsistencyTest < Minitest::Test
  def read_utf8(relative)
    File.read(ROOT.join(relative), encoding: Encoding::UTF_8)
  end

  def test_adr_049_states_the_live_approval_evidence_policy
    adr = read_utf8('documentation/adr/adr-049-chat-approval-is-evidence-gated-and-bound-to-one-exact-prompt.md')
    approve = YAML.safe_load(read_utf8('gems/tamoz-approval/policy/base.yaml')).fetch('evidence').fetch('approve')

    assert_match(/\*\*Status:\*\* Accepted 2026-08-12/, adr)
    assert_includes adr, "`base.yaml` sets `evidence.approve: #{approve}`",
                    'ADR-049 must name the evidence level the shipped base policy requires to approve'
  end

  def test_comms_design_carries_the_retired_adr_043_and_the_adr_049_entry
    design = read_utf8('documentation/design/comms.md')

    assert_match(/ADR-049 — Chat approval is evidence-gated/, design,
                 'the decision list must carry the ADR-049 one-liner')
    assert_match(/ADR-043 — retired, superseded by ADR-049/, design,
                 'the ADR-043 entry must say it was retired into ADR-049')
  end

  def test_the_flow_contract_says_the_section_2_reconciliation_is_resolved
    contract = read_utf8('docs/TELEGRAM_COMMUNICATION_FLOW_CONTRACT_2026-08-12.md')

    assert_match(/§2 reconciliation resolved via exit 2/, contract)
    refute_match(/approved pending §2/, contract,
                 'no stale "blocked" language may survive in the contract header')
  end

  def test_the_bar_grades_c1_met
    bar = read_utf8('docs/TELEGRAM_COMMUNICATION_BAR.md')

    assert_match(/C1 \|.*— \*\*met\*\*/, bar)
    refute_match(/C1 fails today/, bar,
                 'the bar must not contradict the implemented gate')
  end
end

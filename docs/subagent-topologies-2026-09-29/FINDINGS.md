# Subagent topologies — real-model findings (T5/T6, 2026-09-29)

**Real-model results.** Route: OpenRouter `deepseek/deepseek-v4.1-flash`. The offline controls are separate and call
no model (`rake agenteval:topologies:prove`). Reports:
[dev baseline](reports/topologies-20260929-dev-baseline.json) (seeds 1–2, repeat 2, 48 trials),
[tuned dev recheck](reports/topologies-20260929-dev-tuned.json) (HA1–HA4, seed 1, repeat 2, 16 trials), and
[held-out](reports/topologies-20260929-heldout.json) (seeds 3–4, repeat 1, 24 trials). Only the held-out report is a
reported number; the two development-set runs are labelled as such.

## Development set (seeds 1–2)

Baseline: R0 delegation 4/16 (0.25). On-arm solved chain 4/4, survey 6/8, change 2/4; off-arm 4/4, 7/8, 3/4. Review
0/4; fan-out 2/3 of delegating surveys. The note fired — HA2's on-arm received `delegate_nudge` after 27 reads — and
the model kept reading one file at a time; one HA1 trial read 11 files and never reached the old threshold of 12.

Tuning (development-set work, labelled): `nudge_reads` 12 → 6; `delegate_nudge.md` made directive and
topology-specific; `delegate.json` gained a survey/chain trigger and a "before you finish … call delegate with role
review" instruction.

Tuned recheck: R0 6/8 (0.75), fan-out 4/4, review 0/2; solved chain 2/2, survey 2/4, change 0/2.

## Held-out (seeds 3–4, repeat 1)

| Row | Result |
|---|---|
| R0 | **met**: the on-arm delegated in 6/8 `chain`+`survey`+`change` trials (0.75) |
| R1 | **met**: zero child writes, leaks and deleted tests in both arms |
| R2 | **finding**: on-arm solved 4/8 (chain 2/2, survey 2/4, change 0/2) vs off-arm 7/8 (2/2, 4/4, 1/2) |
| R3 | **not met**: 0/4 narrow+trivial trials delegated, but the on-arm spent 119,122 tokens there vs 82,105 off (1.45× > 1.25×) |
| R4 | **not met**: HA3 peak parent prompt on [25,410; 27,244] vs off [22,495; 29,861]; compactions [0,1] vs [0,1] |
| R5 | fan-out **met** (4/4 delegating surveys fanned out); review **not met** (0/2 changes reviewed) |

The loss is fan-out accuracy. HA2.3 fanned out to four children and its merged answer missed 18 handlers; HA3.4
missed 21 and wrongly listed 21. All four on-arm fan-out trials also tripped `step_repetition` (0.54–1.0), so the
children repeat calls while their slices stay incomplete. Both HA4 on-arm trials changed `lib/money.rb` and broke the
hidden `xenon_ledger` caller that a fresh-context `review` would have read; the off-arm fixed it in 1/2.

## What it means

1. **Guidance is the lever that makes the model delegate.** R0 moved 0.25 → 0.75 on the development set and held at
   0.75 held-out, and fan-out became the default shape for a survey (4/4). That is a real behaviour change from
   prompt data alone, with no new machinery.
2. **Delegation did not buy accuracy at this size.** A fan-out's merged answer was less complete than a solo read on
   two of four surveys, and the change tasks got worse because `review` was never chosen. R2 is a finding, not a win.
3. **The unused review is the concrete gap.** The tool description says to review a change that reaches callers, and
   the model edited `lib/money.rb` — called by `labels.rb` and the ledger — without asking for one. The read/window
   note cannot reach HA4: it makes its edit after about two reads, so no note is due.
4. **An offered tool is not free even when unused.** The on-arm pays 1.45× the off-arm's tokens on narrow+trivial
   with zero delegations there; the `delegate` schema and the earlier note ride in every request. Default stays off.

## Next

- Make the fan-out result trustworthy before tuning further: children repeat calls and their slices miss handlers. A
  merge that checks coverage, or a smaller fan-out, is the place to look.
- Give `review` its own trigger; the read/window note cannot reach a quick change turn. This is the R5 miss.
- Do not turn subagents on by default: the narrow+trivial token bound (R3) fails.

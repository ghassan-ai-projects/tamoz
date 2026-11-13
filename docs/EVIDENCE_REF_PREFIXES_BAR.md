# The parser accepts only the evidence ids the frame can offer — quality bar

**Task:** drop the `evidence:` reference prefix that no frame ever offers, and tell the model what to cite instead ·
**Owner:** Ghassan · **Size:** S · **Set:** 2026-11-10 (before the change)
**Plan:** review finding: `ReasoningDocument::REF_PREFIXES` accepts `evidence:`, `EpisodeFrameBuilder#build_evidence_ids`
never lists one, so `EpisodeNodes#ground_evidence!` refuses every `evidence:` reference · **Governing ADRs /
invariants:** P0B/§5 strict parser, P1 frame sections, P2 one repair · **Branch:** `belt-m4-evidence`

## 0. Outcome and fence

**Outcome:** every prefix `ReasoningDocument` accepts is one some frame entry carries, and a reference with any other
prefix is refused at parse with a message that names the citable prefixes and says a tool result is cited by its
`tool:<index>`.

Verified at HEAD before the change: the frame's evidence ids are `fact:`, `skill:`, `memory:` and `tool:<index>` only
(`episode_frame_builder.rb` `build_evidence_ids`); the system section's EVIDENCE line names those four and never
`evidence:`. Tool results are opaque caller JSON; an id the model reads inside one (for example from an `evidence_get`
result) has no frame entry, so it can only be refused as `ungrounded_evidence_refs`, and that message does not say what
to cite.

**Why this fix and not the other:** listing ids found inside tool results would make Tamoz read the shape of a
caller's tool output (a caller's domain, ADR-058) and add a second id source to ground against. A whole tool result is
already citable as `tool:<index>`. Removing the dead prefix is less machinery and keeps the parser and the frame in
agreement.

**Not in scope:** the frame's EVIDENCE line and every prompt template (unchanged: they never offered `evidence:`);
the `ungrounded_evidence_refs` message for a well-prefixed id the frame lacks (unchanged); ids inside tool results.

**Owner decisions needed:** none.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | `ReasoningDocument::REF_PREFIXES` and `parse_evidence_refs` (`gems/tamoz-agent-kernel/lib/tamoz/agent/reasoning_document.rb`) |
| 1.2 | What already does part of it | `EpisodeNodes#repair_directive_for` already puts the rejection text in the one repair; no new path |
| 1.3 | Blast radius | `REF_PREFIXES` has one reader (`parse_evidence_refs`); `git grep` finds no test, fixture or control citing `evidence:` |
| 1.4 | Baseline and known-red | enola MCP is not available in this session: BLOCKED for the snapshot; `rake ci` runs enola. Known-red: `DocumentationTest#test_local_markdown_links_resolve`, from the owner's untracked `outreach/` (stated by the owner) |

## A. Safety and authority

| # | Property | Check | Status |
|---|---|---|---|
| A1 | Grounding is not loosened: a ref the frame did not list is still refused | `test/benchmark_controls_test.rb` forger control and `ground_evidence!` unchanged | PASS: unchanged code; forger test green in `rake ci` |

## B. Function

| # | Property | Check | Status |
|---|---|---|---|
| B1 | The parser's prefixes are exactly the frame's id prefixes | `test/agent_episode_frame_shape_test.rb` — `test_the_parser_accepts_exactly_the_id_prefixes_the_frame_offers`; fails at HEAD (`evidence` extra) | PASS: red before the fix, green after |
| B2 | An `evidence:` ref is repaired with the citable prefixes and `tool:<index>` | same file — `test_a_reference_the_frame_never_offers_is_repaired_toward_the_citable_ids`; fails at HEAD (refused only at grounding, message names nothing) | PASS: red before the fix, green after |
| B3 | No-tools frame bytes unchanged | `test/agent_episode_investigation_test.rb` `NO_TOOLS_DIGEST` | PASS: frame builder untouched; green in `rake ci` |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files | `ruby -Itest test/agent_episode_frame_shape_test.rb`, `ruby -Itest test/agent_reasoning_document_test.rb` | PASS |
| D2 | `LANG=en_US.UTF-8 bundle exec rake ci`, once | output | PASS except known-red: design, `adr:validate` (64 ADRs), `adr:verify` (618 citations), syntax green; `test_fast` 435 runs, 1 failure (the known-red below), 0 errors; `stream:proto:check` and `quality:architecture` run by name after it, exit 0 |
| D4 | RuboCop autocorrect on touched files | `bundle exec rubocop -a <files>` | PASS |
| D5 | enola | `quality:architecture` (`enola check --fail-on=cycles,layers`) | PASS: exit 0; the MCP diff was not available here |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Less machinery: one prefix removed, one message extended | diff review | PASS |
| E2 | No alias or shim for the old prefix | diff review | PASS |
| E3 | No new comments | diff review | PASS |
| E4 | No scratch files | `git status` | PASS |
| E6 | No domain literal; tests use generic ids | review | PASS |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The report says this is plumbing; no model was called | report | PASS |
| F3 | No ADR states the citable prefixes (`git grep` over `documentation/adr`), so none changes; `rake adr:validate adr:verify` green | ADR tooling | PASS: ran in `rake ci` |

## Review log

| Package | Findings (critical / high / medium / low) | Resolution | Commit |
|---|---|---|---|
| prefix fix | 0 / 0 / 0 / 2: helper named like a format, not a message; the message lists `memory:` and `skill:` even when the frame has none | helper renamed `evidence_ref_rejection`; the list stays (qualified by "ids the user message gives") | this commit |

## Loop log

| Iteration | Date | What changed | Rows moved | Still open | Next |
|---|---|---|---|---|---|
| 1 | 2026-11-10 | bar set; B1, B2 written and seen red at HEAD; prefix removed and message extended | B1, B2 to PASS | D2, review | `rake ci`, reviewer |
| 2 | 2026-11-10 | review: helper renamed; `rake ci` once | D2, D5 to PASS | none | done |

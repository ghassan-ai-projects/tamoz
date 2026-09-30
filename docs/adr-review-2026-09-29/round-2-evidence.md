# Round 2 — Evidence, governance, and corrections to round 1

Date: 2026-09-29. Tree inspected: HEAD `192a853c120ef0b5f01ae56f471d1eb05fc5269a` plus the existing working tree.
Pre-existing changes in Rakefile, harness prompts/tests, and another review directory were left untouched.
All 55 ADR pages and the five first-round reports were read. Code inspection was targeted; this is not a full implementation or cross-repository audit.

## Evidence vocabulary and severity

- **Text:** a directly observed statement or contradiction in the ADRs.
- **Code:** an enforcing seam or differing implementation inspected in this tree.
- **Executed:** a check/test run during this round; its coverage remains the scope of that check/test.
- **Judgment:** a design critique or repair recommendation, not a proven runtime failure.
- **Open:** a claim requiring additional evidence or an owner decision.

P1 means a materially misleading authority/recovery claim or acceptance process; fix before treating the corpus as trustworthy. P2 means significant decision-analysis, lifecycle, ownership, or evidence debt. P3 means navigation/editorial cleanup. No P0 runtime incident or exploitable bypass was established in this round. Do not sum the original reports' severity counts: their scopes overlap and their P0 definitions differ.

## E1 — P1: Passing ADR checks does not establish the declared quality bar

**Text:** `documentation/adr/LIFECYCLE.md:38–39` says green checks mean the ADR meets the bar.

**Code:** `script/adr_validate.rb:57–72` checks Context, Decision, Consequences, and references in Status. Verification absence is a warning. It does not enforce the tier-required alternatives, Date, threat model, invariant linkage, or change-bar. `script/adr_verify.rb:22–47` checks existence for selected backticked paths and gem names; it skips symbols, globs, bare filenames, and semantic content.

**Executed:** all checks passed while ADR-008 still claimed three supported pools and ADR-049 still claimed zero residual approval risk. This demonstrates a gap between the named bar and automated coverage, not that every accepted ADR is wrong.

**Repair:** narrow the lifecycle's statement to the actual automated checks; require a recorded semantic grade before claiming acceptance. Extend existing validators for objective metadata/structure rules only. Do not build a semantic-proof engine out of prose matching. Meaningful enforcement evidence still requires human review of tests and paths.

## E2 — P1: Verification sections have no explicit proof scope

A dated citation establishes at most what it names. ADR-004 verifies absence of `tamoz-chain` while deciding that `Tamoz.seq`/`Tamoz.step` are canonical APIs. ADR-020 cites a secret-shaped-value detector for serializer rejection, explicit sensitive fields, authenticated encryption, and cross-surface redaction. ADR-047 cites a gem for export sampling and loss-free paused turns.

For ADR-020, there is useful counter-evidence against declaring the whole feature absent: `StateCodec#encode_node` rejects `Tamoz::Secret`, and `SQLite::Store#protect`/`bytes_for_decode` implement a named protection-codec seam for explicitly sensitive store values. That does not by itself establish authenticated encryption or a uniform policy across checkpoints, streams, errors, logs, and inspect. The correct finding is **insufficiently scoped evidence**, pending a path-by-path audit, rather than an unsupported claim that encryption is missing everywhere.

**Repair:** use a compact proof table in each consequential ADR:

| Claim | Owning facade/seam | Negative scenario | Evidence result | Limit |
|---|---|---|---|---|
| Exact invariant being claimed | Existing owner, with link | Input or failure that must be refused | Test inspected/run, date and revision | Uncovered surface or deployment assumption |

A source inspection, an executed stub test, a real-model run, and a production operating result must be named distinctly. A test path alone is not a passing result.

## E3 — P2: The declared lifecycle and template cannot be followed literally

- `_TEMPLATE.md` offers `Revised`, `Superseded by ADR-M`, and `Retired` statuses; `adr_validate.rb:38–39` only accepts prefixes `Accepted|Proposed|Retired`.
- The lifecycle allows retirement without a replacement; `adr_validate.rb:59–62` requires a successor for every retired record.
- The quality bar requires Date and Relates to broadly; the template permits omitting Relates to. The validator enforces neither.
- The quality bar calls README the single authoritative index; README says catalog is generated from the files, and `adr_catalog.rb` consumes those files. Manual and generated views need a clear authority relationship.
- All cataloged statuses being syntactically accepted today does not make the advertised transitions executable.

**Repair:** use one coherent model for accepted/proposed/retired state, revision history, and replacement relations; make the template and existing tooling agree. ADR Markdown owns decision content/metadata; catalog/graph/traceability are derived views; the human index must agree. Do not create another maintained registry.

## E4 — P2: The duplicate-identity check runs after collisions are discarded

`script/adr_validate.rb:45` assigns records to `adrs[fnum]`. Lines 50–52 look for duplicates among the hash keys, after same-number files have overwritten one another. By inspection, that cannot detect all duplicate filenames; a later link/index check might fail for a different reason, but uniqueness is not proven by this check.

**Repair:** check the collected input filenames before indexing. Add an isolated fixture test with two valid files sharing one ADR number, where the other checks would otherwise pass. Also test Revised, retirement without successor, and the required structures selected in E3. This is a follow-up code change, not implemented during this documentation review.

## E5 — P2: Documentation-only changes can bypass the CI workflow

`.github/workflows/ci.yml:5–16` ignores Markdown, `docs/**`, and `documentation/**` on both PR and main-push events. `Rakefile`'s everyday `ci` includes `adr:validate`, but `adr:verify` is in `ci_full`. An ADR-only change therefore cannot rely on this workflow to run either semantic review or the existence checks automatically.

**Repair:** have a bounded documentation gate run for ADR/catalog/index changes, using the existing commands. Test the triggering path filters and retain the normal lane budgets. This is a workflow recommendation; no CI configuration was changed.

## Adjudication of first-round findings

The original reports are retained as review history. This table overrides their stronger conclusions where new evidence changes them.

| Round-1 claim | Round-2 adjudication | Evidence / consequence |
|---|---|---|
| Missing `ModelClientFactory` (lens 1 findings 11/13) | **Withdraw the missing-symbol suspicion** | It exists at `gems/tamoz-agent-kernel/lib/tamoz/agent/model_client_factory.rb:11`, with multiple production call sites. No transport-removal defect follows from the original limited search. |
| `Tamoz.seq`/`Tamoz.step` not found | **Confirm a documentation/API evidence gap**, bounded to tracked Ruby source search | Searches for definitions, singleton definitions, dynamic symbol definitions, and calls found no matching production API. Do not implement the API solely to make the old ADR true; decide whether the claim is obsolete. |
| 49 of 55 verification lines check out / only four stale | **Do not retain this as an enforcement score** | Existence is weaker than behavior; retired records and Proposed 050 are different cases. Use the all-ADR disposition matrix and claim-level evidence. |
| Missing cancellation and domain-data ADRs are P0 | **Reclassify as P2 governance gaps** | Existing code/rules and digest tests exist; no catastrophic failure was demonstrated. Important missing records still require repair. |
| Revert the 2026-09-24 chat-bound policy unless a new ADR exists | **Reject an automatic policy revert** | ADR-049 explicitly records owner authorization. Repair the current record and risk analysis; changing accepted authority is a separate decision. |
| Only §5/§6 of ADR-049 need correction | **Expand scope** | Abstract, §4, §7, Adoption, ADR-043, and the declared reference-quality bar also depend on the old deny-only posture. |
| ADR-050 means there are now 62 active invariants | **Withdraw the automatic 61→62 correction** | ADR-050 is Proposed; the invariant contract ends at 61. Mark 62 as proposed in traceability until ratified. Do not promote it through a count edit. |
| Every full-page ADR after 049 has complete safety structure | **Incorrect** | ADR-051/052 lack a Threat model section; ADR-053/054/055 lack a dedicated change-bar. Applicability must be reviewed, not inferred from number/length. |
| No consolidation or cross-ADR simplicity concern | **Too strong** | 052's mandatory package-per-concern rule needs a credible internal-module alternative; 055's repository argument conflicts with 040's proximity rule. Preserve distinct decisions while revisiting those arguments. |
| All 38 rejection sections are substantive | **Too strong** | 051/054 include documentation-maintenance choices; several others compare only unsafe or poorly designed options. A row count is not decision quality. |
| All missing alternatives can be transcribed cheaply | **Qualify** | Existing prose supports some rows. Plausible historical alternatives may never have been considered; label new retrospective analysis rather than inventing acceptance history. |
| Reciprocity required for all relates-to links | **Overreach** | Bidirectional replacement/amendment is needed for lifecycle integrity. General dependency references can be directional; requiring every reverse link adds upkeep without stronger semantics. |
| Lens-2 audit reports 10 chain edges | **Arithmetic error** | The table contains 11 edges. This is another reason not to aggregate report tallies. |
| Lens-3 summary: 53 live pages plus 3 tombstones out of 55 | **Arithmetic error** | Corpus is 51 accepted + 1 proposed + 3 retired = 55; 52 non-retired pages. |
| Security apparatus can be filled by converting prose into threat tables | **Insufficient** | The journal-loss, shared-DB, host-versus-runner, digest-authenticity, and approval-risk distinctions require actual analysis. Tables alone do not supply it. |

## Commands executed in this round

Pinned Ruby 3.3.11; one test file per invocation.

| Command | Observed result | What it establishes |
|---|---|---|
| `ruby script/adr_validate.rb` | Pass: 55 ADRs, 0 warnings, next number 56 | Current structural/link/catalog checks only |
| `ruby script/adr_verify.rb` | Pass: 56 citations | Existence/absence checks for recognized citations only |
| `ruby script/adr_catalog.rb --check` | Up to date: 55 ADRs | Generated catalog matches current inputs |
| `ruby -Itest test/comms_evidence_gated_approval_test.rb` | 17 runs, 29 assertions; no failures/errors/skips | Explicit operator-only refusal and chat-bound allowance, binding/expiry scenarios in that file |
| `ruby -Itest test/approval_engine_test.rb` | 26 runs, 95 assertions; no failures/errors/skips | Policy/classification/grant scenarios in that file |
| `ruby -Itest test/observability_runtime_test.rb` | 13 runs, 53 assertions; no failures/errors/skips | Rotation, retention, counted saturation, capture and metric bounds in that file |
| `ruby -Itest test/core_state_codec_test.rb` | 13 runs, 149 assertions; no failures/errors/skips | Codec immutability/validation/Secret refusal in that file |
| `ruby -Itest test/comms_adr049_consistency_test.rb` | 4 runs, 16 assertions; no failures/errors/skips | Selected status/prose assertions; **does not detect the contradictory zero-risk paragraphs** |
| `ruby -Itest test/documentation_test.rb` | 3 runs, 1,689 assertions; no failures/errors/skips | Repository Markdown links, 55-ADR/61-invariant pins, design validation under the C locale |

Total tests: **76 runs, 2,031 assertions, 0 failures, 0 errors, 0 skips** (73 focused behavior/prose runs plus 3 documentation runs). These are deterministic tests, not evidence of model reasoning. No real-provider call, full `rake ci`, RuboCop, Enola snapshot, or cross-repo compatibility gate was run: this round changes review Markdown only and does not claim implementation readiness.

## Reusable lesson

A green citation check plus a populated template can certify an internally contradictory ADR if the gate never checks the claimed behavior. Record proof scope and semantic review separately from structural validation. Keep that distinction in the lifecycle, acceptance rubric, and final review report.

## Additional rule violations encountered

These were not repaired because no production/test Ruby file is in this change.

- `test/comms_evidence_gated_approval_test.rb:272–274`, method `test_an_approve_is_granted_when_the_requirement_meets_chat_bound_evidence`: uses private transaction access and direct `tamoz_comms_approval_prompts` SQL to re-pin evidence. This conflicts with AGENTS.md's absolute gem-facade boundary. The file already has a public prompt-building scenario for chat-bound evidence; review whether the private-store scenario is redundant or needs an owning-gem test.
- `test/support/domain_loader.rb:41–69`: `intent_entry` includes domain-specific `install_watch_condition` schema/preset branches and a fixed `requires_approval`/`per_hour` policy. This conflicts with the data-only/thin-loader directive. Check which fields are wire-contract defaults versus domain content before moving them; digest and parity validation must accompany any repair. No data/digest edit was made here.

## Limits

All-ADR text coverage is complete. Full behavior coverage is not. No source-history reconstruction was attempted to establish the exact reason a past API vanished. The Go authority, current release support on ruby-lang.org, provider/SDK capabilities, and external services were not checked; recommendations here rely on local corpus/code evidence and make no current external-product claims. Unrun test candidates are explicitly named as candidates in the other reports.

# Duplication audit

Date: 2026-08-20  
Repository: /Users/ghassan/my-projects/tamoz  
Assigned focus: syntactic, semantic, protocol, validation, serialization, policy, test-fixture, and cross-gem duplication.

## Executive summary

The repository has deliberate duplication at three boundaries: versioned serialization protocols, independently loadable gem security policies, and generated evaluation fixtures. Most of it is explained by ownership or dependency isolation and should not be collapsed into a generic utility. I found no confirmed behavioral defect caused by duplication.

I found seven actionable maintenance candidates:

| ID | Severity | Classification | Area |
|---|---|---|---|
| D-01 | Medium | Review candidate | Parallel canonical JSON and deep-freeze implementations in tamoz-evals and tamoz-mcp |
| D-02 | Medium | Review candidate | egress declaration validation duplicated between tamoz-agent and tamoz-mcp |
| D-03 | Medium | Review candidate | P8 argv and credential-environment security rules duplicated at the MCP boundary |
| D-04 | Low | Confirmed maintenance duplication | Three identical optional wire-time decoders in tamoz-comms |
| D-05 | Low | Confirmed maintenance duplication | Three identical typed artifact loaders in tamoz-evals |
| D-06 | Low | Confirmed test-fixture duplication | Two 107-line agent-memory fixture generators differ in only two meaningful places |
| D-07 | Low | Review candidate | Byte truncation is centralized for some MCP surfaces but reimplemented for other MCP outputs |

The highest-value result is negative: Tamoz::Core::JCS is already the shared production canonicalizer, Tamoz::Agent::Deliberation and Tamoz::Tools::Skills delegate to it, and graph v2 delegates to it. The remaining canonicalizers are not byte-compatible protocol twins. Replacing them with JCS without a protocol migration would change durable bytes and evaluation digests.

## Scope and method

I inspected the full repository areas requested by the audit README:

- all 13 gem directories under gems/, their gemspecs, entrypoints, library code, READMEs, fixtures, and callers;
- apps/ and all four executable Ruby entrypoints under bin/;
- all 32 files under script/, including executable Ruby scripts without a .rb suffix;
- all 220 files under test/ (212 Ruby tests) and test/support/ fixtures/helpers;
- repository configuration and relevant contracts/documentation, including AGENTS.md, docs/CODING_STANDARD.md, docs/QUALITY_PROGRAM*.md, docs/P10_MCP_PLAN.md, docs/P17_WEBSEARCH_PLAN.md, docs/evaluation-artifacts-v1.md, and docs/CODE_QUALITY.md.

The inventory counted 544 gem files / 442 Ruby files, 2 app files, 4 bin files, 32 script files, and 220 test files. The gem Ruby source contains 69,934 nonblank lines; scripts contain 8,731 and tests 52,965. These are inventory counts, not a quality score.

The analysis loop was:

1. Read repository rules and the audit README; record the existing gem dependency direction.
2. Inventory every component and trace public callers across gem boundaries.
3. Search all in-scope source for repeated canonicalization, hashing, JSON, freezing, validation, policy, truncation, time parsing, fixture-writing, and loader patterns.
4. Compare suspicious implementations by exact source diff and then inspect their actual callers and wire contracts.
5. Use the current Enola graph for symbol exploration and impact checks, then classify each match as harmful duplication, review candidate, or intentional duplication.
6. Revisit generated scripts and test support separately so fixture/test setup repetition was not mistaken for production duplication.

Enola receipt used for architecture evidence: snapshot sha256:5c7d6d74cbe04a9d86ce5c8396157538c253a8b375970f49fdfb2c808aa97b36, Enola 0.2.7-51-g72cd079, 9,659 facts, 52 insights, 495 parsed of 537 seen, and zero parse errors. The receipt reports 599 files and 9 directory trees skipped by ignore globs; those paths are a blind spot described below. The graph is dirty because the repository already contains uncommitted user-owned audit/study directories.

The live Bundler quality commands were not available in this environment: bundle exec rubocop, bundle exec reek, and the quality task fail before execution because Bundler 4.0.12 required by Gemfile.lock is not installed. jscpd, semgrep, ast-grep, and the parser gem were also unavailable. I used Enola's Ruby extraction, rg, exact source diffs, line-numbered source inspection, gemspec dependency inspection, and caller tracing as the documented fallback. No production code or tests were changed.

## Findings

### D-01 — Parallel canonical JSON and deep-freeze implementations

Severity: Medium  
Confidence: High for duplication; Medium for defect risk  
Classification: Review candidate, not a confirmed behavioral defect  
Categories: syntactic, semantic, serialization, protocol, cross-gem

Evidence:

- gems/tamoz-core/lib/tamoz/core.rb:66-102 delegates production canonical JSON and digests to Tamoz::Core::JCS; gems/tamoz-core/lib/tamoz/core/jcs.rb:47-300 owns the RFC 8785 implementation.
- gems/tamoz-evals/lib/tamoz/evals/canonical_json.rb:14-80 independently walks hashes and arrays, normalizes strings to NFC, sorts keys, emits JSON, and computes a versioned tamoz-evals digest. gems/tamoz-evals/lib/tamoz/evals/deep_freeze.rb:8-17 independently recursively freezes artifact trees.
- gems/tamoz-mcp/lib/tamoz/mcp/canonical_json.rb:16-65 repeats the same overall tree-walk shape and also owns an in-place recursive freezer at :23-31. Its own comment at :7-10 says the duplication is deliberate because tamoz-mcp cannot depend on tamoz-evals.
- docs/evaluation-artifacts-v1.md:3-23 explicitly defines Evals v1 as a Tamoz-specific canonical form, not RFC 8785. It rejects floats, duplicate keys, and normalization-colliding keys.
- The behavior is not identical: Evals rejects floats and non-string keys (canonical_json.rb:44-49, :56-64); MCP accepts floats and symbols (canonical_json.rb:43-47), stringifies keys without collision rejection (:52-58), and scrubs invalid strings (:60-65).

Why it matters:

This is a real parallel implementation of a serialization-shaped algorithm, so future fixes to Unicode handling, depth limits, key collisions, or freezing can land in one gem and not the other. The risk is especially high because both APIs are named CanonicalJSON, which makes an accidental substitution look safe. However, the protocols have different accepted values and different digest/wire promises. A single implementation would currently be a semantic regression, not a cleanup.

Root cause, using the 5 Whys:

1. Why are there multiple walkers? Evals owns a versioned artifact protocol and MCP owns an independently loadable catalog/invocation protocol.
2. Why are they not calling the core JCS implementation? Evals v1 deliberately predates and differs from JCS; MCP cannot depend on Evals and its accepted value set differs.
3. Why is drift still possible? The shared-looking algorithm is copied rather than represented by a shared contract fixture.
4. Why is a shared runtime helper risky? It would silently change durable bytes, error behavior, or accepted values.
5. Root cause: protocol ownership is explicit, but the common subset and intentional differences are not enforced by one parity matrix.

Recommendation:

- Do not replace either implementation with Tamoz::Core::JCS and do not create a generic CanonicalJSON gem from this audit alone.
- Add a protocol conformance matrix/fixture for the common finite JSON subset, plus explicit divergence vectors for floats, symbols, invalid encoding, non-string keys, and NFC key collisions. The matrix should assert bytes and rejection behavior, not merely object equality.
- On a future protocol revision, consider protocol-specific names such as ArtifactJSON and CatalogJSON to make ownership visible. Treat that as a public/wire-surface change and preserve the existing Evals digest version and MCP snapshot bytes until an intentional revision is approved.
- Keep Tamoz::Core.deep_freeze separate: it rebuilds containers and normalizes keys, while Evals/MCP freeze in place. An extraction is justified only if two consumers require the same ownership and mutation semantics.

### D-02 — Egress declaration validation is duplicated across tamoz-agent and tamoz-mcp

Severity: Medium  
Confidence: High for duplication; Medium for drift risk  
Classification: Review candidate; intentional gem-boundary duplication, no confirmed defect  
Categories: validation, policy, protocol, cross-gem

Evidence:

- gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:101-130 defines the egress key set, HTTPS-only scheme, request/response/timeout/redirect/circuit bounds, host/IP patterns, and credential-shaped-name policy.
- gems/tamoz-agent-profile/lib/tamoz/agent/profile/egress_validator.rb:50-224 validates the profile declaration: shape, exact FQDNs, IP-literal refusal, limits, circuit fields, and credential references.
- gems/tamoz-mcp/lib/tamoz/mcp/websearch/egress_policy.rb:9-42 explicitly describes the copy as deliberate and repeats the same schema vocabulary, bounds, regexes, and policy constants. Construction and validation are at :54-88 and :178-230.
- The MCP policy also owns runtime/per-hop behavior at egress_policy.rb:97-154; the agent validator does not. Tamoz::Mcp::Websearch::EgressClient is therefore not a duplicate of the profile validator even though it consumes the same declaration.
- docs/P17_WEBSEARCH_PLAN.md:82-88 acknowledges the duplication and requires one budget vocabulary. test/websearch_egress_test.rb:87-115 exercises profile admission/replay, while test/websearch_adapter_test.rb:47-115 exercises per-hop enforcement.

Why it matters:

The duplicated admission rules are a security contract. A bound, pattern, or credential-name rule can be changed in one gem and not the other. That can create a profile that pins successfully but is rejected by the operator-side adapter, or a policy object that accepts a declaration with a different security meaning. The current source comments and plan make the boundary intentional, so this is not evidence that extraction into tamoz-agent is correct.

Recommendation:

- Keep profile pinning/validation in tamoz-agent and per-hop enforcement in tamoz-mcp; do not introduce a dependency from MCP to Agent or a generic EgressPolicy base class.
- Add a shared contract vector for the declaration shape and limits. Run it against both validators and assert equivalent accept/reject outcomes for hosts, schemes, bounds, circuit fields, credential references, and exotic IP spellings. Keep error classes/messages local.
- If a third real consumer appears, evaluate a small low-level declaration gem containing only versioned data and pure validation. Do not extract merely because the methods look alike; the operator enforcement and authority pinning must remain separate.
- Any policy change should update both copies in one reviewed change and run the full MCP, profile, packaging, and security regression gates.

### D-03 — P8 argv and credential-environment rules are repeated at the MCP boundary

Severity: Medium  
Confidence: High for duplication; Medium for drift risk  
Classification: Review candidate; intentional security duplication, no confirmed defect  
Categories: validation, policy, cross-gem, syntactic

Evidence:

- gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:138-145 owns shell metacharacter and argv policy constants; gems/tamoz-agent-profile/lib/tamoz/agent/profile/check_spec_validator.rb:79-105 validates argv elements.
- gems/tamoz-tools/lib/tamoz/tools/check_runner.rb:13-24 centralizes the tools gem's credential environment pattern and names; gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:41-42 delegates its public constants to CheckRunner.
- gems/tamoz-mcp/lib/tamoz/mcp/server_config.rb:37-56 repeats the shell metacharacter pattern, credential pattern, and credential-name list. It applies them at :347-405, including argument and environment allowlist validation.
- docs/P10_MCP_PLAN.md:115-125 explicitly calls the credential-env copy deliberate so tamoz-mcp does not depend on tamoz-agent.

Why it matters:

This is defense-in-depth at an independent process boundary. If the lists or regexes diverge, a command admitted by one surface may be refused by another, or an environment variable classified as credential-bearing in one child process may be allowed in another. The differences are not wholly accidental: profile validation also has an argv[0] denylist, while MCP owns server command admission and its own error taxonomy.

Recommendation:

- Do not move these rules into tamoz-agent or a generic security utility solely to remove repeated literals; that would violate the intended load-time isolation and could make a low-level gem own unrelated command authority.
- Add a focused parity corpus for the shared threat vocabulary: shell metacharacters, C0/DEL controls, NUL, credential-shaped names, explicit TAMOZ_* references, and the known provider credential names. Test each consumer against it while preserving consumer-specific argv[0] and path rules.
- Keep the canonical policy vocabulary in the plan/docs and require a paired update when a security literal changes. A future shared package should be considered only after a third consumer and a clearly owned, versioned policy contract exist.

### D-04 — Three identical optional wire-time decoders in tamoz-comms

Severity: Low  
Confidence: Very high  
Classification: Confirmed maintenance duplication; no observed runtime defect  
Categories: syntactic, serialization, validation

Evidence:

~~~ruby
def self.wire_time(wire, key)
  value = wire[key]
  value && Time.parse(value)
end
~~~

The implementation is identical at:

- gems/tamoz-comms/lib/tamoz/comms/approval_prompt.rb:137-140;
- gems/tamoz-comms/lib/tamoz/comms/decision_record.rb:214-217;
- gems/tamoz-comms/lib/tamoz/comms/inbound_envelope.rb:109-112.

gems/tamoz-comms/lib/tamoz/comms/shapes.rb:5-27 already centralizes common field-shape predicates, so this is the one small repeated wire-boundary helper that escaped the existing seam. The surrounding validation is intentionally different: approval, decision, and inbound envelope have different required fields and state rules.

Why it matters:

Three copies can diverge in nil handling, timestamp parsing, or error normalization. A wire value is an authority boundary, so inconsistent optional-time behavior would be difficult to diagnose.

Recommendation:

Add a narrow parser seam, preferably Comms::WireTime.optional(wire, key) or an equivalently explicit helper. Do not turn Shapes into a generic validator. Before extraction, characterize nil, valid ISO timestamps, invalid timestamps, and non-string values; preserve the existing Time.parse exception behavior unless the protocol intentionally standardizes it.

### D-05 — Three identical typed artifact loaders in tamoz-evals

Severity: Low  
Confidence: Very high  
Classification: Confirmed maintenance duplication; no observed runtime defect  
Categories: syntactic, semantic, validation

Evidence:

- gems/tamoz-evals/lib/tamoz/evals/case.rb:5-17, evidence.rb:5-19, and result.rb:5-19 each verify a path, check one literal artifact type, then call new(attributes:, path:, digest:) with the same verification fields.
- The shared construction target is gems/tamoz-evals/lib/tamoz/evals/artifact.rb:5-22, which deep-freezes the attributes, expands the path, freezes the digest, and freezes the value.
- The only intended variation is the expected type and the noun in the error message (case, evidence, or result). Public callers include script/run_m1_conformance:162, script/run_m2_conformance:169, test/evidence_artifact_test.rb:11, and test/public_api_test.rb:124-126.

Why it matters:

The three methods must remain aligned on verifier construction and returned immutable state. A later change to verifier invocation, path handling, or digest wiring can update one artifact type and silently leave the others behind.

Recommendation:

Add one inherited/private Artifact.load_typed(path, expected_type) helper that performs verification, preserves the type-specific error text, and instantiates self. Each public loader should remain as a small, readable type declaration. Existing wrong-type, digest, path, and immutability tests should be retained or expanded around the shared helper. This meets the coding standard's two-real-consumer rule without introducing a generic service layer.

### D-06 — Near-identical agent-memory fixture generators

Severity: Low  
Confidence: Very high  
Classification: Confirmed test-fixture duplication; no observed generated-artifact defect  
Categories: syntactic, test-fixture, serialization

Evidence:

- script/generate_agent_memory_fixtures:16-25 and script/generate_agent_memory_repository_fixtures:16-25 contain the same write_case implementation and both use the Evals canonical digest/writer.
- Their case_document envelopes are identical from :28-97, including suite ID, artifact metadata, budgets, evidence, scorer, and treatment fields.
- The two 107-line scripts differ meaningfully only at :13 (case root) and :99 (corpus class); diff -u confirms the rest is the same. The repository generator still uses the shared AgentMemoryCorpus::SUITE_ID at :36, which is consistent with the repository corpus comment that it shares suite identity.
- script/generate_agent_smoke_fixtures:16-106 is the same envelope family but has enough protocol-specific differences—suite/kind/evidence/scorer/isolation/treatments—to remain a separate variant unless the common writer is made explicit.

Why it matters:

Generated files are committed and the coding standard requires generator/output consistency. Near-copies are easy to update asymmetrically when adding a new envelope field, budget, or evidence rule. The current repository and memory-repository scripts already demonstrate that corpus-specific data is separate from the stable envelope, so the duplication is a maintenance risk rather than a behavior defect.

Recommendation:

- Prefer one parameterized agent-fixture generator with an explicit suite/corpus configuration, or extract only the stable write_case/envelope builder into a small script-local helper. Keep corpus definitions and protocol-specific fields visible and typed rather than hiding them behind a generic fixture framework.
- Preserve deterministic canonical output and the existing generator commands only if they are still operational entrypoints; otherwise make the consolidation an intentional script-interface change. Regenerate artifacts and run the fixture byte-identity tests after any change.
- Do not hand-edit generated JSON to resolve this duplication; the generator and output must move together.

### D-07 — MCP byte truncation is only partially centralized

Severity: Low  
Confidence: High for repeated operation; Medium for defect risk  
Classification: Review candidate, not a confirmed defect  
Categories: semantic, policy, validation

Evidence:

- gems/tamoz-mcp/lib/tamoz/mcp/bounded_text.rb:5-22 centralizes UTF-8 coercion, invalid-byte scrubbing, control replacement, whitespace trimming, and UTF-8-safe truncation. Catalog and elicitation use it at catalog.rb:177-178 and elicitation.rb:254-255.
- gems/tamoz-mcp/lib/tamoz/mcp/websearch/egress_client.rb:241-250 independently performs byteslice(...).scrub("").rstrip for bounded HTTP response bodies.
- gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb:681-689 independently scrubs text and truncates content blocks with the same byte-safe expression.
- These are not byte-for-byte equivalent policies: BoundedText replaces controls and strips outer whitespace; invocation scrubs controls in a separate method; the websearch response preserves raw response semantics except for byte bounding.

Why it matters:

Three output surfaces use similar UTF-8 boundary logic but have different trust and rendering contracts. A future fix to one copy can introduce invalid UTF-8, control leakage, or changed response bytes in another surface. Blindly routing all three through BoundedText would be wrong because the policies deliberately differ.

Recommendation:

First define the invariant per surface: display text, MCP content blocks, or opaque provider response body. If the only shared invariant is UTF-8-safe byte slicing, consider a private low-level byte-slice helper with no scrubbing or policy decisions. Keep control stripping, whitespace behavior, truncation markers, and response metadata at each boundary. Add adversarial multibyte and invalid-byte vectors before extraction.

## Intentional duplication and false positives

These matches were examined and are not recommended for consolidation in the current design:

| Area | Evidence | Why it is intentional |
|---|---|---|
| Core JCS vs Graph canonicalization | gems/tamoz-graph/lib/tamoz/graph/canonical.rb:7-27 | Graph v2 delegates to Core JCS; its v1 local rule is a versioned historical checkpoint format. Removing v1 logic would change old durable identities. |
| Core/Agent/Tools canonical delegation | gems/tamoz-tools/lib/tamoz/tools/skills.rb:94, gems/tamoz-agent/lib/tamoz/agent/deliberation.rb:318, test/p16_tools_gem_test.rb:244-247 | These are callers of one Core implementation, not copies. The equality test is a good anti-duplication guard. |
| Comms canonical bytes vs Core JCS | gems/tamoz-comms/lib/tamoz/comms/canonical.rb:8-59 | Comms uses a channel-specific scalar encoding, Time handling, and newline-domain scheme. It is not a JSON/JCS protocol and must not be merged by name similarity. |
| Observability content canonicalization | gems/tamoz-observability/lib/tamoz/observability/content_policy.rb:104-158 | This implementation bounds depth/entries, refuses secrets, detects string/symbol key collisions, and supports content-policy-specific capture. It is a redaction/budget policy, not a general digest codec. |
| Evals deep freeze vs Core deep freeze | gems/tamoz-evals/lib/tamoz/evals/deep_freeze.rb:8-17, gems/tamoz-core/lib/tamoz/core.rb:141-158 | Evals freezes input in place; Core rebuilds containers, stringifies keys, and rejects unsupported values. The ownership and mutability invariants differ. |
| MCP and Agent egress validator vs runtime client | gems/tamoz-mcp/lib/tamoz/mcp/websearch/egress_policy.rb:97-154 | Declaration admission and per-hop SSRF/rebinding enforcement are separate security phases. Shared code would obscure authority and enforcement ownership. |
| OTel egress policy | gems/tamoz-otel/lib/tamoz/otel/egress_policy.rb:9-82 | OTLP has one configured endpoint, an explicit allow_local option, resolved-address checks, and exporter-specific limits. It does not implement websearch's exact-FQDN allowlist or redirect policy. |
| Evals verifier status cases | gems/tamoz-evals/lib/tamoz/evals/verifier.rb:325-371 and :473-525 | Evidence and result artifacts share a status taxonomy and diagnostic helper but have different claims/hard-gate/reference invariants. A data-driven status table would hide protocol semantics; the case statements are intentional. |
| Evals harness path/capability checks | sqlite_scenario_runtime.rb:66-74, sqlite_convergence_probe.rb:202-210, sqlite_scenario_driver.rb:119-143, sqlite_convergence_probe.rb:221-247 | Similar method names validate different runtime prerequisites, file existence, and size/ownership guarantees. No shared invariant was established. |
| SQLite address and canonical helpers | gems/tamoz-sqlite/lib/tamoz/sqlite/store.rb:376-405, checkpoint_store.rb:140-177, boundary_registry.rb:395-408, wire.rb:22-71 | Store namespaces, checkpoint identities, registry fingerprints, and SQLite wire digests are different protocol contracts. The private registry sorter is intentionally local. |
| Communication value validators | approval_prompt.rb:144-197, decision_record.rb:221-314, inbound_envelope.rb:120-194, shapes.rb:5-27 | Common field predicates are already shared; identity, lifecycle, evidence, and command validation are not interchangeable. |
| Test/support fixture servers | test/support/telegram_fixture_server.rb:52-107, test/support/mcp_http_fixture_server.rb:36-110 | Both need an accept loop, but they speak different protocols and intentionally test different wire behavior. A generic fake server would reduce test clarity. |
| Test skill writers and repeated setup | test/agent_skills_adversarial_test.rb:23-37, test/agent_skills_toolbox_test.rb:33-50 | Test-local builders are similar but configure different frontmatter and ownership scenarios. They are not production duplication and remain easy to read at the test site. |
| Domain fixtures | test/fixtures/domains/*.json, test/support/domain_loader.rb | AGENTS.md requires domain knowledge to remain data-only and loaded through the domain loader. Reusing or extracting domain literals into Ruby would violate the repository's policy. |
| M0/M1/M2 fixture generators | script/generate_m0_fixtures:19-28, generate_m1_fixtures:16-26, generate_m2_fixtures:16-26 | All emit Evals artifacts, but each milestone has a different suite schema, evaluator, and evidence contract. Only the stable writer is a possible future extraction. |

## Cross-gem ownership and dependency conclusion

The gem graph explains most of the cross-gem duplication:

~~~text
tamoz-core
├── tamoz-tools ── tamoz-agent
├── tamoz-graph ── tamoz-sqlite ── tamoz-agent
├── tamoz-comms ── tamoz-telegram
├── tamoz-observability ── tamoz-otel
├── tamoz-mcp
└── tamoz-scheduler / tamoz-stream

tamoz-evals -> core, agent, sqlite, mcp
~~~

tamoz-agent deliberately does not depend on tamoz-mcp, and tamoz-evals is outside the production runtime graph. Therefore:

- extracting Evals code into MCP would invert the evaluation/runtime boundary;
- extracting MCP policy into Agent would give Agent ownership of an operator-side process contract;
- extracting Agent policy into Core would make the lowest-level gem own higher-level command and network authority;
- extracting every canonicalizer into one package would conflate at least four incompatible byte protocols.

The appropriate shared artifacts are parity vectors and byte-level contract tests, not a generic Utils or BasePolicy class. This follows docs/CODING_STANDARD.md:141-150 and docs/QUALITY_PROGRAM.md:18-27: composition, narrow public APIs, explicit boundaries, and at least two real consumers before an abstraction.

## Prioritized follow-up

1. Add a contract matrix for the Agent/MCP egress declaration and P8 credential/argv rules. This is the best risk-reduction step because it protects security policy while preserving gem isolation.
2. Characterize and extract the three Comms wire_time copies and the three Evals typed loaders. These are small, behaviorally equivalent, and low-risk after tests pin error/nil behavior.
3. Decide whether the agent-memory generator pair should become one parameterized generator. Keep corpus data and generated output explicit.
4. Add canonicalization conformance vectors for Evals/MCP shared inputs and divergence cases. Consider protocol-specific names only during a deliberate public/protocol revision.
5. Revisit MCP truncation only if a concrete policy mismatch or duplicated change appears; the current implementations intentionally serve different data classes.

No production code or tests should be changed solely from this report. Any implementation slice should first use Enola impact analysis, add characterization tests, run rake ci, rubocop, enola check, and preserve all digest/wire fixtures.

## Component coverage checklist

Status means the component was inventoried and its duplication-relevant code/callers were searched, not that it contains a finding.

| Component | Inventory | Duplication-relevant areas examined | Status |
|---|---:|---|---|
| tamoz-core | 33 files / 30 Ruby | Core canonical/JCS, deep freeze, immutable/safe text, digest helpers, callers | Complete |
| tamoz-agent | 132 / 128 Ruby | Profile schema/egress/check validation, Deliberation canonical delegation, gem boundary | Complete |
| tamoz-tools | 27 / 24 Ruby | Skills canonical delegation, Toolbox/CheckRunner env policy, workspace helpers | Complete |
| tamoz-graph | 51 / 48 Ruby | Canonical v2 Core delegation and v1 historical codec, checkpoint wire | Complete |
| tamoz-sqlite | 70 / 67 Ruby | Wire digests, store/checkpoint normalization, boundary registry fingerprints, callers | Complete |
| tamoz-comms | 25 / 22 Ruby | Shapes, channel canonicalizer, all value from_wire/validation code | Complete; D-04 |
| tamoz-telegram | 8 / 5 Ruby | Transport/client normalization and Comms seam use | Complete |
| tamoz-observability | 21 / 18 Ruby | ContentPolicy canonicalization, bounded content, signal/record serialization | Complete; intentional policy copy |
| tamoz-otel | 8 / 5 Ruby | OTLP egress policy/exporter and observability boundary | Complete; intentional protocol difference |
| tamoz-mcp | 20 / 17 Ruby | CanonicalJSON/deep freeze, ServerConfig security rules, websearch egress, bounded text | Complete; D-01/D-02/D-03/D-07 |
| tamoz-scheduler | 11 / 8 Ruby | Schedule contract and storage seam | Complete; no harmful duplication found |
| tamoz-stream | 34 / 25 Ruby | Stream contracts, worker/codec use of Core, boundary callers | Complete; no harmful duplication found |
| tamoz-evals | 103 / 44 Ruby | CanonicalJSON/deep freeze, artifact loaders, verifier, harness/corpora | Complete; D-01/D-05 |
| apps/ | 2 files | README and app manifest; no Ruby implementation | Complete |
| bin/ | 4 executable Ruby scripts | Entry-point loading and delegation; no repeated domain implementation found | Complete |
| script/ | 32 executable Ruby scripts | All generator, benchmark, quality, conformance, and runtime scripts; exact generator diffs | Complete; D-06 |
| test/ and test/support/ | 220 files / 212 Ruby | Test builders, fixture servers, canonical/protocol vectors, generated fixture tests | Complete; intentional repetitions classified |
| Config/docs/contracts | 271 files matching audit globs | AGENTS, coding standard, quality program/state, gem READMEs, P10/P17, Evals v1, baseline | Complete |

## Coverage and blind spots

Counts and coverage:

- 13 gems, 2 app files, 4 bin entrypoints, 32 scripts, and 220 test files were enumerated.
- 442 gem Ruby files, 32 executable scripts, and 212 Ruby test files were source-searched.
- All 13 gemspecs and the dependency boundary were inspected.
- Enola parsed 495 of 537 seen files with zero parse errors. Its receipt records 599 files and 9 directory trees skipped by ignore globs; ignored generated/cache/worktree paths were not treated as source evidence.
- The current audit folder already contains the audit README and may receive reports from the other independent passes. This report only adds duplication.md.

Blind spots:

- No live RuboCop, Reek, full Rake, SimpleCov, mutation, or runtime test signal was available because Bundler 4.0.12 is missing and the system Ruby is 2.6 while the repository requires Ruby 3.3+. Historical values in docs/CODE_QUALITY.md:3-14 are earlier baselines, not current duplication measurements.
- No AST-level clone detector was available. Exact source diffs, repeated method searches, Enola symbol extraction, caller inspection, and protocol docs were used instead. Very small normalized clones may remain undiscovered.
- Runtime behavior across lazy autoload paths and dynamically composed test harnesses was not executed. The source and Enola graph were used to trace those callers, but this cannot prove every branch is exercised.
- Generated JSON/fixture content was not treated as source duplication unless its generator logic was duplicated. Domain data was deliberately classified under the AGENTS.md data-only rule.
- The audit does not claim that every repeated scalar literal is a defect. Bounds often belong to different security or wire protocols even when their numeric value matches.

## Final classification

- Confirmed behavioral duplication defects: 0.
- Confirmed maintenance/test-fixture duplication: 3 (D-04, D-05, D-06).
- Medium review candidates requiring parity/contract protection: 3 (D-01, D-02, D-03).
- Low review candidate requiring policy-specific judgment: 1 (D-07).
- Intentional or false-positive duplication clusters documented: 14.


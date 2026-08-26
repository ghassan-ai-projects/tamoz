# Gateway reading-order refactor bar

## Scope

- Entry point: `Tamoz::Comms::Gateway` in
  `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb`.
- Defect: the extracted entrypoint is 939 lines and mixes process lifecycle,
  admission, commands, pairing, status projections, callback decisions, and
  delivery construction at several abstraction levels.
- Owned files: `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway*.rb`,
  `gems/tamoz-comms-gateway/README.md` if its protocol description needs
  correction, and focused existing gateway tests only when needed to prove
  preservation.
- Read-only dependencies: `tamoz-comms` values/contracts, SQLite-backed
  adapters, `tamoz-agent-cli`, and repository test support.
- Forbidden: public constant renames, compatibility aliases, behavior changes,
  fixture/fake/test-server additions, cross-gem contract changes, and unrelated
  cleanup.

## Behavior contract

- Preserve `Gateway`'s public namespace, constructor behavior, public methods,
  return symbols, exceptions, durable store mutations, transport call order,
  lease fences, authentication/identity refusal, callback decisions, command
  replies, pairing, pacing, controls, and shutdown behavior.
- Preserve all existing private behavior unless a test demonstrates an
  extraction-only defect. No lifecycle redesign is authorized by this bar.
- The top-level reading path must tell this story without opening a helper:
  startup acquires and authenticates; one pass renews, polls, admits, persists,
  and drains; the loop delays and stops; cleanup releases the lease.
- Details must move into named cohesive concepts: inbound admission and
  callbacks, command/control routing, pairing, status projection, and outbound
  delivery construction.

## Must-pass criteria

- [x] `gateway.rb` is at most 300 lines and contains the public lifecycle story,
      construction, and only small seam methods; extracted files are named by
      domain responsibility, not generic helpers.
- [x] Each extracted method stays at one abstraction level and adds domain
      meaning; no shallow wrapper or duplicated implementation is introduced.
- [x] `Tamoz::Comms::Gateway` remains the only public class and all existing
      callers require it through `tamoz/comms/gateway`.
- [x] Focused gateway, callback, command, pairing, control, drainer, and
      supervision tests pass with unchanged observable behavior.
- [x] Authentication preflight and descriptor-derived callback metadata remain
      covered; no direct Telegram dependency or fixture enters the package.
- [x] New/changed files pass syntax, targeted RuboCop, `git diff --check`, and
      package/dependency isolation checks.
- [x] The independent reviewer returns `PASS` for every criterion; known
      repository baseline failures are listed without being relabeled.

## Evidence

- Before baseline: current gateway test pass counts and the 939-line reading
  defect are recorded before the refactor.
- After evidence: exact focused test commands/counts, file-size and source
  ownership checks, package fixture scan, targeted RuboCop, and architecture
  snapshot/diff where available.

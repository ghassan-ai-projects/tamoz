# Small improvements

## One-hour improvement loop

Owner request: keep making incremental improvements for one hour and commit each
completed change. Started 2026-09-04 23:03:50 UTC; target end 2026-09-05 00:03:50 UTC.
Each increment follows trace → test → simplify/fix → review → validate → commit.
Keep cross-gem interfaces unchanged and do not weaken existing gates.

### Increment 2: regenerate the ADR catalog

The locked JSON 2.21.2 formatter emits empty arrays as `[]`; the committed
catalog used the older multiline spelling. Regenerated with the existing
`script/adr_catalog.rb`, with parsed JSON equality against HEAD proving that all
55 ADR records are unchanged. `rake adr:validate` and the generator's `--check`
now pass. `rake ci` gets past ADR validation and into the existing test failures.
This is documentation metadata, with no runtime or protocol changes.

## 2026-09-05: simpler capability registry construction

Status: implemented; focused validation passed. Repository-wide gates remain red.

The existing seam is `Tamoz::Core::Capability::Registry.build` in
`gems/tamoz-core/lib/tamoz/core/capability/registry.rb`. Its consumer is
`gems/tamoz-tools/lib/tamoz/tools/capability_host.rb`: construction, inventory,
and dispatch. Public methods and cross-gem interfaces stay identical.

### Problem and change

Construction wrapped each descriptor in `{source:, descriptor:}`. The source
entry was never consumed; routing already uses the registry's sources. Building
the declared inventory then allocated another hash just to unwrap descriptors.
Store descriptors directly and select the admitted, enabled surface from that
map. Index normalized admission IDs once with a hash, removing an array scan
for each descriptor. Expected membership work becomes O(A + D), instead of
O(A * D), for A admission IDs and D descriptors. No new dependencies or classes.

### Acceptance bar

- Preserve source/descriptor validation, collision refusal, sealing, descriptor
  identity, insertion order, frozen maps, and source routing.
- Hash admission uses keys, regardless of values; arrays accept duplicate IDs;
  both normalize symbols to strings. Unknown IDs never add descriptors.
- Disabled and unadmitted descriptors remain in the declared inventory only.
- Add behavior tests before implementation; run registry and consumer tests,
  `rake ci`, RuboCop, changed-file Reek parity, and Enola checks.

### Evidence

- Clean starting working tree; Ruby 3.3.11 via `rbenv exec bundle exec`.
- Existing registry tests: 9 runs, 28 assertions, passing.
- Four added characterization tests pass before implementation: 13 runs,
  57 assertions in total.
- Enola baseline pinned before implementation. Its extractor does not expose
  methods inside this `Data.define` block, so direct caller/source reading
  supplements the architecture map.
- Baseline changed-file Reek: 8 smells.
- After implementation: 74 tests / 1,547 assertions pass across
  `capability_registry`, `capability_host`, `capability_inventory`,
  `capability_closed_world`, `public_api`, `dependency_isolation`, and
  `documentation_surface` test files. Each file ran separately.
- Four in-memory mutations were rejected by the tests: sorting the surface,
  admitting disabled descriptors, treating empty admission as unrestricted,
  and accepting invalid admission. No mutation was written to production files.
- Both changed Ruby files pass RuboCop. Changed-file Reek falls from 8 to 6
  smells, with no new contexts. Production implementation is three lines shorter.
- `rake syntax stream:proto:check` and `git diff --check` pass.
- Enola check passes; snapshot comparison reports zero new findings. Its 19
  added call edges belong to the expanded registry tests.

### Repository-wide gate blockers

- `rake ci` stops at ADR validation because `documentation/adr/catalog.json`
  is stale. The same stale-catalog failure reproduces at unchanged HEAD in a
  detached temporary worktree.
- Full RuboCop reports 3,894 offenses across 902 files in both unchanged HEAD
  and this working tree; the edited Ruby files have none.
- `rake test_fast`: unchanged HEAD has 2,365 runs, 39 failures, 30 errors;
  this tree has 2,369 runs, 38 failures, 30 errors. Of 68 failing/erroring test
  names in this tree, 66 also fail in the baseline. This is not a green gate.
  The other two were investigated: the thermal adversarial test passes alone
  in both trees; the broken roadmap link exists unchanged at HEAD. The baseline
  documentation test excludes all paths containing `tmp`, so its passing result
  there performs zero assertions and cannot establish link correctness.
- The added tests account for the four additional fast-suite runs. Timing and
  checkout-location differences prevent claiming exact full-suite parity.
- Leave the generated global quality baseline unchanged while the wider test
  gate is red, consistent with the live state's existing regeneration blocker.
  Do not absorb unrelated lint debt into a newly generated baseline.

### Follow-up ideas

Only investigate another optimization when a real caller or measurement justifies
it. In particular, keep the existing source routing rather than adding a second
index for the small built-in source list.

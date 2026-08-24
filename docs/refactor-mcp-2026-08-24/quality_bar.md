# Clean-Code Quality Bar — tamoz-mcp refactor

This is the definition of done for the `gems/tamoz-mcp` refactor. Every file in the gem is judged against these five principles and the concrete checks below.

## Principles

1. **A function name states its intent.** The reader should know what the function does from its name; names like `handle`, `process`, or `do_it` are not acceptable.
2. **A function is short and does one thing.** A function should be small enough to read without scrolling and should have only one reason to change.
3. **A function stays at one level of abstraction.** A public function calls domain-level operations; it does not mix high-level policy with byte-level string manipulation in the same body.
4. **Public, top-level functions read like a small domain-specific language.** The public API of a class/module tells the story of the domain in the order it is used.
5. **Each function calls functions one level below it, and the code keeps stepping down until the remaining operations are small and concrete.** The code forms a top-down staircase, not a flat list of equal-level details.

## Concrete checks

### For every file

- [ ] Public methods are intention-revealing and free of implementation-detail names.
- [ ] No method does two distinct things (no `and`/`or` in names; no side tangents).
- [ ] No method mixes abstraction levels (no high-level orchestration plus low-level byte slicing in one body).
- [ ] Private helpers are extracted so the public method reads as a short sequence of named steps.
- [ ] No obviously duplicated logic is left inline when a named helper would clarify intent.
- [ ] Comments are not used to explain what code does; they are only used for non-obvious "why" (safety invariants, failure models, rejected alternatives).
- [ ] Behavior is preserved; any intentional behavior change is recorded in `docs/refactor-mcp-2026-08-24/behavior_changes.md`.
- [ ] The file still passes `rubocop` for the changed lines and the project test suite at the end.

### End-state bar

- [ ] Every `.rb` file in `gems/tamoz-mcp/lib` has been reviewed and, if needed, refactored.
- [ ] Each refactor is committed separately with a clear message.
- [ ] A final `rake test` (or equivalent) run passes.
- [ ] No structural regression is reported by enola (or the delta is understood and accepted).

## How the bar is checked

After a file is edited:

1. Re-read the file and score it against the five principles.
2. Run `rubocop` on the file.
3. If any principle is violated, extract another helper or rename another function and re-check.
4. Only commit once the file passes the bar.

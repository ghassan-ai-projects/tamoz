# Clean-Code Quality Bar — tamoz-agent-healing refactor

## Principles

1. **A function name states its intent.**
2. **A function is short and does one thing.**
3. **A function stays at one level of abstraction.**
4. **Public, top-level functions read like a small domain-specific language.**
5. **Each function calls functions one level below it, and the code keeps stepping down until the remaining operations are small and concrete.**

## Concrete checks

### For every file

- [ ] Public methods are intention-revealing.
- [ ] No method does two distinct things.
- [ ] No method mixes abstraction levels.
- [ ] Private helpers are extracted so public methods read as short sequences of named steps.
- [ ] No obviously duplicated logic is left inline.
- [ ] Comments are only used for non-obvious "why".
- [ ] Behavior is preserved; any intentional behavior change is recorded in `behavior_changes.md`.
- [ ] The file passes `rubocop`.

### End-state bar

- [ ] Every `.rb` file in `gems/tamoz-agent-healing` has been reviewed and, if needed, refactored.
- [ ] Each refactor is committed separately.
- [ ] The project test suite passes.
- [ ] `enola check` reports no structural regression.

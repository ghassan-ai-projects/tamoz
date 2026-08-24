# Behavior decisions intentionally deferred

This refactor keeps current behavior. The following cleaner behavior opportunities were
identified but are not implemented because they would change an observable contract or
failure model:

- `WorkerRuntime#session_for_child` loads profiles directly instead of using the
  monitor/cache path used by `profile`; changing that may alter load timing and profile
  identity.
- `WorkerRuntime#enqueue_child_task` releases capacity after any post-reservation failure,
  including a retry that found an existing active reservation; changing this requires an
  explicit reservation-ownership model.
- `WorkerRuntime#tombstone_schedule` writes the tombstone before deleting the payload;
  atomic retirement or recovery-state handling would change failure artifacts and needs a
  durability decision.
- `WorkerRuntime#close_approval_session` closes every bound session despite its singular
  name; renaming it would change a public interface.
- `RuntimeDirectory#migrate!` reads the config after `resolve` has already loaded it;
  reusing the first document would change behavior if the file changes between reads.
- `RuntimeDirectory#approval_policy_path` resolves relative overrides from the process
  working directory while `skills_root` resolves relative paths from the runtime directory;
  normalizing those bases would change configuration semantics.

No behavior change is authorized for this task unless explicitly approved later.

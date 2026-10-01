# Files — one write primitive

- **An owner-only directory is `Tamoz::Core::PrivateDirectory.secure`**, not `mkdir_p(mode:)` + `chmod 0o700`:
  `mkdir_p`'s mode only applies to directories it creates, so a pre-existing loose one stayed loose.

- **Durable bytes go through `Tamoz::Core::AtomicFile`** (`replace` for an existing name, `create` for a new
  one that must not race). A hand-rolled `File.write` + `chmod`, or temp + rename without the fsyncs, either
  tears on a crash or exposes the bytes at the default umask until the chmod lands. `mode:` sets the file's
  mode before it is published; `Tempfile` makes it 0600, so pass `0o644` where the old write was readable.
- **Rename swaps the inode, so a `flock` on the data file stops serializing.** Lock a dedicated `.lock`
  file, as `TransitionRegistry` and `SearchLedger#charge!` do.
- **A config backup is a create, not a copy:** `FileUtils.cp` then `chmod` exposes the bytes at the umask.
- **The sanctioned exceptions are named in `test/atomic_file_boundary_test.rb`**: the SQLite backup, log
  rotation, the skill directory swap. Add a file there only with the reason; the test fails when an
  exemption goes stale.
- **A conversion test asserts the call, not the bytes.** `atomic_writes { ... }` (test_helper) records what
  AtomicFile published; a before/after byte check passes on the old code too.
- **Not every write is durable state.** `RecorderJournal#persist_health` runs per dropped signal on the
  producer's thread; a four-fsync replace there stalls the overload path. Check the call frequency first.
- **`Tempfile` is 0600, the old `File.write` honoured the umask.** Pass `0o666 & ~File.umask` to keep it.

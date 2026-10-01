# Files — one write primitive

- **Durable bytes go through `Tamoz::Core::AtomicFile`** (`replace` for an existing name, `create` for a new
  one that must not race). A hand-rolled `File.write` + `chmod`, or temp + rename without the fsyncs, either
  tears on a crash or exposes the bytes at the default umask until the chmod lands. `mode:` is set before
  the file is published.
- **`Tempfile` stages 0600; a plain `File.write` honoured the umask.** Pass `AtomicFile::DEFAULT_MODE` where
  the old write was meant to be readable. Never call `File.umask` per write: with no argument it clears and
  restores the process umask, and a thread creating a file in that window gets 0666.
- **An owner-only directory is `Tamoz::Core::PrivateDirectory.secure`**, not `mkdir_p(mode:)` + `chmod 0o700`:
  `mkdir_p`'s mode only applies to directories it creates, so a pre-existing loose one stayed loose.
- **Rename swaps the inode, so a `flock` on the data file stops serializing.** Lock a dedicated `.lock`
  file through `Tamoz::Core::FileLock.exclusive`, as the adoption and transition registries and
  `SearchLedger#charge!` do; the read-modify-write belongs inside the lock.
- **A config backup is a create, not a copy:** `FileUtils.cp` then `chmod` exposes the bytes at the umask.
- **Not every write is durable state.** `RecorderJournal#persist_health` runs per dropped signal on the
  producer's thread; a four-fsync replace there stalls the overload path. Check the call frequency first.
- **The sanctioned exceptions are named in `test/file_facades_boundary_test.rb`**: the SQLite backup, log
  rotation, the skill directory swap. Add a file there only with the reason; the test fails when an
  exemption goes stale.
- **A conversion test asserts the call, not the bytes.** `atomic_writes { ... }` (test_helper) records what
  AtomicFile published; a before/after byte check passes on the old code too.

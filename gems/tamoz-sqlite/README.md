# tamoz-sqlite

SQLite persistence for Tamoz. The facade is `Tamoz::SQLite::Adapter`; graph compilation binds
its durable checkpointer, requests, effects, approvals and schedules through the owning APIs.

`Tamoz::SQLite::RecordReader.open(path:)` is the read-only reconstruction facade. It verifies the
existing schema and pins a read snapshot; it never migrates or opens a writer. Its bounded
`requests`, `effects`, `effect_attempts`, `checkpoints`, `approval_decisions` and `occurrences`
queries return frozen metadata and digests. A failure returns only validated class/code identifiers;
payloads, responses, results, checkpoint state and schedule completion evidence are excluded.
Call `close` when finished. Observability consumes this facade by duck type.

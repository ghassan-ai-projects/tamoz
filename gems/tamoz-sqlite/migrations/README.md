# Migrations

`NNNN.sql` builds the whole schema: its statements joined by the line `-- tamoz migration boundary --`, its checksum
the SHA-256 of the file. There is no upgrade path before 1.0 (ADR-059): a fresh database is built from it, the current
one is verified, and any other version is refused with an instruction to start a fresh runtime database.

A schema change replaces the file with the next ordinal (`0028.sql`, `CURRENT_VERSION = 28`); an ordinal is never reused.
Ordinals 1–26 were squashed into 0027; their history is in git.

# tamoz-agent-cli

The command line for Tamoz agents: the `tamoz` executable and every command
group — worker, schedule, profile, session, comms. Extracted from
`tamoz-agent`, which becomes a pure library; the namespace stays
`Tamoz::Agent::CLI`.

## Public surface

- **`CLI.run`** — the single entry point (`exe/tamoz` is a two-line shim).
- **Command groups** (modules included into `CLI`): `CLIWorkerCommands`,
  `CLIScheduleCommands`, `CLIProfileCommands`, `CLISessionCommands`,
  `CLICommsCommands`, `CLICommsDoctor`, `CLICommsOps`.
- **Support seams**: `CLIAuthority` (credential/authority prompts),
  `CLIRendering` (output shaping over the runtime's terminal progress),
  `CLIPromptAdapter`, `CLIArgumentParser`, `CLIOptionPolicy`.

## Dependencies

`tamoz-agent` only — everything below the runtime arrives transitively.
No upward edges: nothing in this gem is required by another gem.

## Versioning

Released in lockstep with the rest of the Tamoz family: every gem pins its
dependencies at `= #{VERSION}` and all gems share the single hand-synced
version literal (`0.1.0.alpha.1`).

# tamoz-agent-profile

The trusted-profiles vertical for Tamoz agents: operator-side validation of
profile documents (structure, authority, egress, check specs), secure file
handling, and the two operator-side registries — adoption and transition.
Extracted from `tamoz-agent`; the namespace stays `Tamoz::Agent::Profile`.

## Public surface

- **`Profile`** — the facade: `preview`, `load`, `from_authority`,
  `resolve_path`, `preview_source`, `profiles_dir`, `adoption_path`,
  `suggestion_path`. It assembles the validators and registries below; it is
  not a re-export shim.
- **Validators**: `DocumentValidator`, `AuthorityValidator` (resolves graph
  versions through the kernel's `GraphVersions`), `EgressValidator`
  (`Tamoz::Core::SECRET_VALUE_PATTERNS`-aware content scanning via
  `ContentScanner`/`YamlScanner`), `CheckSpecValidator`.
- **Files and locations**: `SecureFile`, `Locations`, `Fields`.
- **Registries**: `AdoptionRegistry` (+ `AdoptionDocument`),
  `TransitionRegistry` (+ `Transition`, `TransitionDocument`).
- **Errors**: under `ProfileError < Tamoz::Agent::Error`.

## Dependencies

`tamoz-agent-kernel` (`Error`, `GraphVersions`), `tamoz-core`. No sqlite
dependency: the one `CheckpointWire` mention is a comment, and no runtime deps: no session,
worker, CLI, graph, comms, approval, or stream code — the subtree's only
"stream" mentions are comments about YAML event streams.

Consumers: the agent session/CLI wiring and the eval harness bind to the
`Tamoz::Agent::Profile` facade; nothing reaches past it.

## Versioning

Released in lockstep with the rest of the Tamoz family: every gem pins its
dependencies at `= #{VERSION}` and all gems share the single hand-synced
version literal (`0.1.0.alpha.1`).

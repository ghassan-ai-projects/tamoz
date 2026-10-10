# ADR-062 — A runtime is one agent; channels are ways in to it

**Status:** Accepted 2026-10-10
**Date:** 2026-10-10
**Tier:** F
**Implementation:** Partial — built and plumbing-tested; the owner's live runtime moves to it in P7 of `docs/one-setup-2026-10-09/PLAN.md`
**Relates to:** [ADR-016](./adr-016-every-external-effect-is-journaled-and-ambiguity-stops-as-unknown.md) (`start`'s probe calls), [ADR-042](./adr-042-channel-gateway-is-a-separate-process-in-the-connector-zone.md) (one gateway process per channel, each with its own credential), [ADR-048](./adr-048-tamoz-owns-the-model-boundary-one-digest-bound-openai-compatible-transport.md) (a role names the variable that holds its key), [ADR-059](./adr-059-no-backward-compatibility-before-1-0.md) (the old commands and variables are removed, not aliased), [ADR-061](./adr-061-the-talk-channel-is-a-browser-surface-whose-voice-is-presentation.md) (the talk channel)

One runtime folder is one agent: one workspace, one set of models, one chat profile. Telegram and the talk page
are ways in to it with the same abilities and the same provider; the CLI, given the runtime, shares its models.

## Context

Before this change each channel had its own setup and start (`telegram setup|start`, `talk setup|start`), its
own profile id, and models chosen from environment variables (`TAMOZ_PROVIDER`, `TAMOZ_<ROLE>_*`). The talk
page and Telegram could answer with different models and different tools, the Telegram worker lacked the
web-search keys, and a launchd service was a hand-edited plist. The owner asked for one setup, abstracted,
used by every channel (`docs/one-setup-2026-10-09/PLAN.md`, owner decisions OD1–OD5).

## Decision

- **Models live in the runtime config.** `config.yaml`'s `models` names `chat`, `transcription`, `vision` and
  `voice` (`RuntimeModels`); a role's `credential` names an `*_API_KEY` variable, never the key. `.env` holds
  keys and endpoints only. No code reads a model from the environment; `--provider/--model` override one run.
- **One chat profile per runtime.** Every channel names the same profile (`RuntimeDirectory`'s one-profile
  rule). `tamoz setup` writes it once; no command rewrites it, because bound threads pin its digest.
- **Four commands.** `tamoz setup` (workspace, models, profile), `tamoz channel add telegram|talk`, `tamoz start`
  (checks, then one gateway per channel and one worker, supervised), `tamoz service install|status|uninstall`
  (the same children as launchd jobs).
- **Each child gets exactly its keys, from the config.** `ChildEnvironments` gives the worker its models' keys
  and the enabled sources' variables, never a channel token or the env file; the Telegram gateway its token;
  the talk gateway its token and the voice key, never the chat key.

## Consequences

- The talk page and Telegram share memory rules, tools, approvals and the chat model by construction.
- A model change is one `setup` run and touches no profile, so no bound conversation breaks.
- **Cost:** the old commands and model variables are gone (no alias), so every script, eval and guide moved to
  `setup`, `channel add` and `start` in the same change, and the live runtime needs a one-time migration.
- Changing the workspace of a lived-in runtime, several runtimes on one machine (launchd labels are not
  runtime-scoped), and `channel list/remove` are future work in the plan.

## Invariants

- Every channel of a runtime names one profile, and an existing profile is never rewritten.
- The models of a runtime come from its config or from flags for one run, never from a `TAMOZ_*` variable
  (harness scripts choose theirs with `AGENTEVAL_*` and pass it to `tamoz` by flag).
- No child holds a key its command does not use: the chat key never reaches a gateway, a channel token never
  reaches the worker.

## Threat model

| Threat | Mitigation |
|---|---|
| A key is written into the config | `models.<role>.credential` must name an `*_API_KEY` variable; a provider must look like a provider name; refusals never echo the value |
| The talk gateway gets the chat key | Its environment holds only the voice role's key; `start` refuses a voice key that equals the chat key by name or by value |
| A source names a channel token or the env file | The worker drops channel tokens and `TAMOZ_ENV_FILE` from source variables; the runtime's own keys are set last |
| Secrets leak through the service | Plists and their backups are written 0600 through `AtomicFile`; a `.env` others can read is refused; `service status` never runs `launchctl print` |
| A second run fights the first for a channel | `start` refuses a channel whose lease a live run holds, and a runtime a loaded job serves |

**Residual risk:** one runtime per machine; a second runtime's launchd jobs would share labels.

## History

- 2026-10-10: accepted with phases P1–P5 of the one-setup plan.

# Phase 4 boundary evidence: `tamoz-comms-gateway`

This is the post-extraction source map and behavior ledger. It separates
evidence that the package boundary is correct from safety work that predates
the extraction.

## Source map

| Responsibility | Owner | Evidence |
| --- | --- | --- |
| Gateway lifecycle, lease, authentication, poll, offset, and drain orchestration | `tamoz-comms-gateway` | `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb` |
| Inbound admission and binding | `tamoz-comms-gateway` | `gateway_admission.rb`, `gateway_admission_binding.rb` |
| Callback decision and acknowledgement | `tamoz-comms-gateway` | `gateway_callbacks.rb`, `gateway_admission_acknowledgement.rb` |
| Commands, context controls, pairing, and status projection | `tamoz-comms-gateway` | `gateway_commands.rb`, `gateway_conversation_commands.rb`, `gateway_context_controls.rb`, `gateway_pairing.rb`, `gateway_status.rb` |
| Outbound delivery construction | `tamoz-comms-gateway` | `gateway_delivery.rb`, `delivery_drainer.rb` |
| Channel values, errors, transport and CommsStore contracts | `tamoz-comms` | `gems/tamoz-comms/lib/tamoz/comms/` |
| Telegram HTTP and normalization | `tamoz-telegram` | `gems/tamoz-telegram/lib/tamoz/telegram/` |
| CLI construction and process supervision | `tamoz-agent-cli` | `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_commands.rb` |

The production caller is `Tamoz::Agent::CLICommsCommands`; repository test
support remains outside the package. The new gem declares only
`tamoz-comms` and `tamoz-core`, and its tarball contains no fixture, fake,
mock, stub, test-server, OpenClaw, Telegram, agent, evals, or model source.

## Behavior ledger

| Concern | Extraction evidence | Status |
| --- | --- | --- |
| Startup authentication and configured bot identity | `Gateway#start`; `test/comms_gateway_test.rb`; installed packaging smoke | PASS |
| Poll ordering and durable disposition before offset persistence | `Gateway#serve_once`; `test/comms_gateway_test.rb` | PASS, behavior preserved |
| Delivery claim and send-start fence | `DeliveryDrainer#send_row`; `test/delivery_drainer_test.rb` | PASS, behavior preserved |
| Ambiguous send and receipt projection | `DeliveryDrainer#send_delivery`; `test/delivery_drainer_test.rb`; Telegram mapping tests | PASS, behavior preserved |
| Journal binding ownership | SQLite `CommsOutbox` lifecycle plus CommsStore binding | PASS, no second journal introduced |
| Callback identity/source | Descriptor-derived `kind`; callback tests | PASS for the closed Telegram v1 schema |
| Parent load and installed package isolation | `test/dependency_isolation_test.rb`; `test/packaging_test.rb` | PASS |
| No fixture in the new gem | Tarball path/source scan in `test/packaging_test.rb` | PASS |
| Offset persistence lease fencing | Existing CommsStore API has no owner/fence arguments | BASELINE BLOCKER; not redesigned in extraction |
| Pacing claim renewal | Existing delivery contract has no renewal operation | BASELINE BLOCKER; not redesigned in extraction |
| Prompt activation crash recovery | Existing success marking precedes prompt activation | BASELINE BLOCKER; not redesigned in extraction |
| Signal-driven sibling shutdown | CLI supervisor path exists; direct signal subprocess evidence is absent | EVIDENCE GAP; no extraction change |

The three baseline blockers are safety-contract follow-up slices, not hidden
package defects. Phase 4 must not be described as closing those system-level
gaps until their contracts and migrations are implemented and reviewed.

## Verification record

- Gateway refactor: 35 runs / 194 assertions.
- Delivery drainer: 10 runs / 50 assertions.
- Dependency isolation: 21 runs / 215 assertions.
- Packaging: 13 runs / 589 assertions.
- Public API: 3 runs / 1,054 assertions.
- Requirements manifest: 11 runs / 2,976 assertions.
- Targeted Gateway RuboCop: 11 files / 0 offenses.
- Telegram fixture-server integration is environment-blocked in the sandbox by
  socket-bind `EPERM`; the injected transport classification checks remain
  separate from real-provider evidence.

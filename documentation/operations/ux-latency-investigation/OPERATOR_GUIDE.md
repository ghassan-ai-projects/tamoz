# Operator guide for latency routing and channel recovery

## Routing modes

The safe default is the legacy lifecycle. The experimental fused router is opt-in:

```text
tamoz --experimental-routing TASK
tamoz --shadow-routing TASK
```

`--shadow-routing` records the route while retaining the legacy answer. The
experimental route can also be selected for a durable CLI session or worker:

```text
tamoz --session-dir RUNTIME/sessions --session THREAD --experimental-routing ask TASK
tamoz --runtime-dir RUNTIME --experimental-routing worker
```

The worker still owns the durable execution and authority checks. Routing does not
grant capabilities. A malformed route, an unsafe direct response, or an unavailable
action capability falls back to the legacy lifecycle. Remove `--experimental-routing`
as the kill switch; existing v1 threads continue with the v1 graph definition.

Direct responses are conversational responses, not evidence-backed task completion.
Requests involving workspace files, current external state, commands, or changes must
remain on a work route.

## Telegram delivery

Run the gateway and worker as separate supervised processes. The gateway admits input;
the independent delivery drainer claims outbound rows without waiting for the next
inbound long poll. `--once` performs one bounded poll and one bounded drain pass.

An ambiguous send is durable `unknown`. Do not retry it by changing the row back to
`pending`; reconcile it explicitly with the delivery command documented by the comms
surface:

```text
tamoz comms delivery resolve DELIVERY_ID succeeded
tamoz comms delivery resolve DELIVERY_ID failed
tamoz comms delivery resolve DELIVERY_ID abandoned
```

The `succeeded` choice is an operator assertion that the provider delivered the
message. It is not proof reconstructed by the agent.

## Channel controls

- `/help` returns the bounded command list.
- `/status` reports the redacted conversation state and open-request count. It does
  not expose workspace content, prompts, model output, or another conversation's
  state.
- `/cancel` creates the existing typed redirect for the conversation's bound thread.
  Arguments cannot select another thread, profile, root, tool, or budget.

Accepted acknowledgements and terminal deliveries are separate durable intents. A
terminal answer is counted independently from the acknowledgement, and ambiguous
visibility remains honest.

# Tamoz agent kernel file-by-file refactor checklist

Process each item independently: candidate → implementation or explicit leave-unchanged
decision → review/fix → commit/bar check. Per-file evidence notes are intentionally not retained.

- [x] `gems/tamoz-agent-kernel/LICENSE` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/README.md` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/behavior_version.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb` — prompt sections/structural checks split; `46421da`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/diagnosis_catalog.rb` — description/invariant validation split; `368f55b`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb` — run contract/decision/error completion split; `7f1953d`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_frame_builder.rb` — frame entry groups split; `52fed89`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_call.rb` — journal/outcome mapping split; `5ba26d8`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb` — request/response transport split; `8a764d7`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb` — validation/compensation workflow split; `95a0d99`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_tool_call.rb` — capability/dispatch/outcome flow split; `020c80d`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/errors.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/event.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/graph_versions.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/intent_catalog.rb` — entry construction responsibilities split; `7d8f470`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/kernel/version.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/model_receipt.rb` — receipt validation/role resolution split; `4a26fbe`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/plan.rb` — raw step parsing split; `1b0777c`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/providers.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/reasoning_document.rb` — probability/recommended-intent parsing split; `addba08`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/receipt_budget_controller.rb` — receipt usage reconciliation split; `1f70145`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/request_projection.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/request_route.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/sealed_build.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/skill_set.rb` — wire parsing split; `f397b56`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/witness_gateway.rb` — witness request/record flow split; `d36eece`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/witness_verifier.rb` — signature/receipt binding flow split; `061c4c3`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent_kernel.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/tamoz-agent-kernel.gemspec` — reviewed; unchanged

# Tamoz agent kernel file-by-file refactor checklist

Process each item independently: candidate → implementation or explicit leave-unchanged
decision → review/fix → commit/bar check. Per-file evidence notes are intentionally not retained.

- [x] `gems/tamoz-agent-kernel/LICENSE` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/README.md` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/behavior_version.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb` — committed as `46421da`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/diagnosis_catalog.rb` — committed as `368f55b`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb` — slice PASS; committed as `7f1953d`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_frame_builder.rb` — slice PASS; committed as `52fed89`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_call.rb` — slice PASS; committed as `5ba26d8`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb` — slice PASS; committed as `8a764d7`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb` — slice PASS; committed as `95a0d99`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_tool_call.rb` — committed as `020c80d`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/errors.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/event.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/graph_versions.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/intent_catalog.rb` — slice PASS; committed as `7d8f470`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/kernel/version.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/model_receipt.rb` — committed as `4a26fbe`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/plan.rb` — committed as `1b0777c`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/providers.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/reasoning_document.rb` — slice PASS; committed as `addba08`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/receipt_budget_controller.rb` — committed as `1f70145`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/request_projection.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/request_route.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/sealed_build.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/skill_set.rb` — committed as `f397b56`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/witness_gateway.rb` — committed as `d36eece`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/witness_verifier.rb` — committed as `061c4c3`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent_kernel.rb` — reviewed; unchanged
- [x] `gems/tamoz-agent-kernel/tamoz-agent-kernel.gemspec` — reviewed; unchanged

# Tamoz agent kernel file-by-file refactor checklist

Process each item independently: candidate notes → implementation → independent
review/fix → commit → bar check. Do not run tests until the final checklist pass.

- [ ] `gems/tamoz-agent-kernel/LICENSE`
- [ ] `gems/tamoz-agent-kernel/README.md`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/behavior_version.rb`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb` — slice PASS; commit pending
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/diagnosis_catalog.rb`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb` — slice PASS; committed as `7f1953d`
- [x] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_frame_builder.rb` — slice PASS; committed as `52fed89`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_call.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb` — candidate complete; implementation queued
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_tool_call.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/errors.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/event.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/graph_versions.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/intent_catalog.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/kernel/version.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/model_receipt.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/plan.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/providers.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/reasoning_document.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/receipt_budget_controller.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/request_projection.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/request_route.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/sealed_build.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/skill_set.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/witness_gateway.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent/witness_verifier.rb`
- [ ] `gems/tamoz-agent-kernel/lib/tamoz/agent_kernel.rb`
- [ ] `gems/tamoz-agent-kernel/tamoz-agent-kernel.gemspec`

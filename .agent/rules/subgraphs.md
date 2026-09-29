# Durable subgraph identity

- Give each child execution a deterministic request ID. The effect journal keys model calls by logical request, so sibling children with the parent's request ID can return each other's receipts. `SubgraphRuntime#child_context` is the seam; `test/subagent_spec_test.rb` exercises two delegations in one turn.
- On recovery, read a child checkpoint through the checkpointer bound to the child namespace. The parent codec cannot decode it. `SubgraphRuntime#run` and `test/subagent_kill_test.rb` prove this across a process kill.

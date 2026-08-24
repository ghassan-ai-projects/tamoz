# Bar — tamoz-stream clean-code refactor

A file passes when all of the following hold:

1. **Intent-revealing names.** Every function name states what it does in
   domain terms. No `do_`, `run_stuff`, `handle_data`, or abbreviation names.
2. **Short, one thing.** A method does one job; as a rule of thumb ≤ 10 lines
   before extraction is warranted. Guards may add lines but not jobs.
3. **One level of abstraction per method.** An orchestrating method contains
   no string munging, hash plumbing, or wire-format details inline.
4. **Public top-level functions read like a small DSL.** Reading a public
   entry point reads like the domain operation it performs, step by step.
5. **Step-down rule.** Each function calls helpers one level below it; the
   ladder bottoms out in small concrete operations.
6. **Behavior-preserving.** Pure renames/moves/extractions only. Any change
   that alters observable behavior is either applied deliberately (with a
   dated entry in `behavior-notes.md`) or recorded there as a recommendation.
7. **No new machinery.** No abstractions beyond what step-down requires;
   existing seams are extended, not duplicated. No rubocop-driven edits;
   tests run once at the end of the whole pass, not per file.

Out of scope: `lib/tamoz/stream/gen/**` (generated gRPC code), `version.rb`.

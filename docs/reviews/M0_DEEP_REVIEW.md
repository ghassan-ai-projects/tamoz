# M0 deep review

Review target: `03a2108 build evaluation-first M0 foundation`

Scope: evaluator correctness, artifact semantics, security boundaries, gem packaging,
dependency isolation, CI portability, and test credibility. Runtime behavior beyond M0 was
explicitly excluded.

## Findings

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| High | Valid non-ASCII JSON could crash duplicate-key detection. | The scanner treated one UTF-8 byte as a complete character. | Scan structural string bytes directly and delegate decoded string validation to Ruby JSON. |
| High | `Tamoz::Evals.verify` returned a frozen wrapper around mutable verified evidence. | Immutability was applied only by `Case` and `Result`, not at the verification boundary. | Deep-freeze normalized documents and resolved references before returning verification. |
| High | Referenced evidence was unbounded and could change between metadata and digest reads. | The verifier trusted path containment and digest alone. | Add declared sizes, per-file and aggregate bounds, regular-file checks, and stable single-handle reads. |
| High | Result v1 could not represent provenance and failure classes required by the design. | The initial schema optimized for the M0 fixture rather than the durable result contract. | Add component/snapshot/fixture provenance, attempts, seed/repetition, comparison method, evidence gaps, and infrastructure errors. |
| High | The published `tamoz-evals` gem omitted its public suites and baseline. | Shared package patterns included schemas and code but not evaluation data. | Package suites and baselines and assert their exact presence. |
| Medium | The schema subset silently ignored unknown keywords and implemented `anyOf` as `oneOf`. | The validator had no supported-keyword self-check and conflated two JSON Schema operators. | Reject unsupported schema keywords and require one-or-more `anyOf` matches. |
| Medium | CI actions were mutable tags and jobs had no time or concurrency bounds. | The first workflow covered versions but not supply-chain and resource controls. | Pin official action revisions, disable persisted credentials, add concurrency cancellation and a 15-minute timeout. |
| Medium | Syntax validation was manual, and the documented example path did not exist. | The encoded CI gate and documentation tests did not cover these claims. | Add syntax to `rake ci`, correct the command, and add regression coverage. |

## Residual release checks

M0 remains pre-release. GitHub-hosted matrix execution and RubyGems namespace reservation
require external actions and are not proven by a local commit. No graph, persistence, agent,
memory, healing, MCP, scheduling, skills, streaming, or physical-world runtime behavior is
claimed.

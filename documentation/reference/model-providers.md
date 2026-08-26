# Model providers

Tamoz production model calls use the kernel-owned `ModelClientFactory` and the
single `EpisodeModelTransport` OpenAI-compatible request shape.

| Provider | Protocol | Default base | Credential | API-base override | Model rule |
|---|---|---|---|---|---|
| `openai` | direct OpenAI-compatible | `https://api.openai.com/v1` | `OPENAI_API_KEY` | `OPENAI_API_BASE` | non-empty provider model id |
| `deepseek` | direct OpenAI-compatible | `https://api.deepseek.com` | `DEEPSEEK_API_KEY` | `DEEPSEEK_API_BASE` | non-empty provider model id |
| `openrouter` | gateway, OpenAI-compatible | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` | `OPENROUTER_API_BASE` | provider-qualified model id |
| `ollama` | direct local OpenAI-compatible | `http://localhost:11434/v1` | optional `OLLAMA_API_KEY` | `OLLAMA_API_BASE` | non-empty local model id |
| `xai` | direct OpenAI-compatible | `https://api.x.ai/v1` | `XAI_API_KEY` | `XAI_API_BASE` | non-empty provider model id |
| `perplexity` | direct OpenAI-compatible | `https://api.perplexity.ai/v1` | `PERPLEXITY_API_KEY` | `PERPLEXITY_API_BASE` | non-empty provider model id |
| `mistral` | direct OpenAI-compatible | `https://api.mistral.ai/v1` | `MISTRAL_API_KEY` | `MISTRAL_API_BASE` | non-empty provider model id |
| `anthropic` | native protocol rejected | none | `ANTHROPIC_API_KEY` | `ANTHROPIC_API_BASE` | fail closed; use `openrouter` explicitly |
| `gemini` | native protocol rejected | none | `GEMINI_API_KEY` | `GEMINI_API_BASE` | fail closed; use `openrouter` explicitly |

`anthropic` and `gemini` are not silently redirected. Operators using those
model families must select `openrouter` and provide its provider-qualified
model identifier.

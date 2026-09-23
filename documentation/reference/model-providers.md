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

## Context windows

The coding work loop (`tamoz code`) manages the model's context window, so it
needs the window size of the route it calls. The window is resolved in this
order:

1. The profile role's `normalized_settings.context_window`, written as a string
   (for example `context_window: "163840"`).
2. The `TAMOZ_CONTEXT_WINDOW` environment variable.
3. The route's recorded window in
   `gems/tamoz-agent-kernel/data/model_windows.yml`, keyed on `provider/model`.

A route is keyed on the pair, not the model name alone, because one model can
have a different window at each gateway. A route with no recorded window and no
override is refused before any model call.

Recorded routes (each entry in the file names its source and the date it was
checked):

| Route | Context window | Max output |
|---|---|---|
| `deepseek/deepseek-flash` | 1,048,576 | 393,216 |
| `deepseek/deepseek-v4-pro` | 1,048,576 | 393,216 |
| `openrouter/deepseek/deepseek-v4.1-flash` | 1,048,576 | 384,000 |
| `openrouter/deepseek/deepseek-v4-flash` | 1,048,576 | 384,000 |
| `openrouter/deepseek/deepseek-chat` | 163,840 | 16,384 |

To add a route, read the window from the provider's model listing and record
it with its `source` and `checked` date.

The work loop does not run through the stream episode path's witness gateway.
OpenRouter, a gateway provider, is supported.

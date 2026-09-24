# Goal — Telegram chat that works and feels good

Owner request (2026-09-24): make Telegram usable, with a good experience, and iterate
against a real provider until the bar is met. The bar was written from what a person
expects of a chat agent, before reading the code.

## The bar

| # | Expectation | Eval check (`script/telegram_chat_eval`) |
|---|---|---|
| S1 | One documented command starts the bot from a token and a provider key. | manual + setup scenario (planned) |
| S2 | A missing or refused token or provider key is one clear error, not a hang. | `provider_down` |
| S4 | Strangers never reach the model or tools. | `stranger` |
| C1 | `hi` gets a reply in under 15s, with a typing indicator meanwhile. | `greet` |
| C2 | A fact from the previous turn is remembered. | `memory` |
| C3 | Replies read like chat: no request refs, verification labels, progress trailers, JSON. | every scenario (`no internal jargon`) |
| C4 | Arabic in, Arabic out. | `arabic` |
| C5 | Long answers arrive whole and never exceed Telegram's limits. | `long`, every scenario (`every send accepted`) |
| C6 | `/new` starts fresh; `/help` lists the commands. | `reset`, `help` |
| W1 | A question about the workspace is answered from the files. | `workspace_read` |
| W2 | A change is made (with Approve on the phone when policy asks). | `create_file` |
| R1 | A provider failure tells the user what is wrong within 30s. | `provider_down` |
| R2 | Two quick messages both get answers. | `burst` |
| R4 | A photo gets a polite "text only" reply. | `photo` |

Owner decision D1 (2026-09-24): the paired owner can **Approve** from Telegram, not only Deny.

## How the eval works

`bundle exec ruby script/telegram_chat_eval [--only a,b] [--routing experimental]` starts the
real `tamoz comms serve` (with only the Bot API origin pointed at a local fake) and the real
`tamoz worker` on a real provider (default OpenRouter `deepseek/deepseek-chat`), then plays
each scenario as a Telegram user. The fake refuses what Telegram refuses (empty or
over-4096-character text, edits of unknown messages). Checks read observations — a fact
recalled, a file on disk, a refused send, a request's recorded status, elapsed time — never
the model's wording. The report and transcript land in `tmp/telegram-eval/<stamp>/`.

## Scorecard

| Iteration | Change | Result |
|---|---|---|
| 0 | Eval built. Baseline on the documented setup (legacy routing). | 20/37. Every reply is 3 bubbles wrapped in request refs and "Verified/Not verified" trailers; `hi` answered "A friendly response was not generated and displayed"; "count to 1200" silently created a file; creating `notes.txt` failed; a refused provider key surfaces as "resolve the unknown effect". |
| 0 | Same eval, `--routing experimental`. | 25/39. Right answers (memory, file created, long answer, burst), direct replies in ~6s. Everything that fails is the chat surface. |
| 0 | Same eval, `--routing work`. | 21/39. `/new` did not reset, `README.md` missed, the counting task hung. The coding loop is not the chat engine. |

Found outside the eval: the owner's DeepSeek account is out of credit (`Insufficient Balance`), so
every message the owner ever sent failed; and `scripts/start-tamoz-comms.sh` launches
`gems/tamoz-agent/exe/tamoz`, which does not exist.

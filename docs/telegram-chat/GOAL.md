# Goal — Telegram chat that works and feels good

Owner request (2026-09-24): make Telegram usable, with a good experience, and iterate
against a real provider until the bar is met. The bar was written from what a person
expects of a chat agent, before reading the code.

## The bar

| # | Expectation | Eval check (`script/telegram_chat_eval`) |
|---|---|---|
| S1 | One documented command starts the bot from a token and a provider key. | `setup` (the eval's gateway and worker now run on the runtime the real `tamoz telegram setup` wrote) |
| S2 | A missing or refused token or provider key is one clear error, not a hang. | `provider_down`, plus CLI setup/start error tests (missing/refused token, missing/refused/out-of-credit key) |
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

`bundle exec ruby script/telegram_chat_eval [--only a,b] [--routing experimental]` writes the
runtime with the real `tamoz telegram setup` command (against the local fake Bot API), then
starts the real `tamoz comms serve` (with only the Bot API origin pointed at the local fake) and
the real `tamoz worker` on a real provider (default OpenRouter `deepseek/deepseek-v4.1-flash`, work
routing), and plays each scenario as a Telegram user. The fake refuses what Telegram refuses
(empty or over-4096-character text, edits of unknown messages). Checks read observations — a fact
recalled, a file on disk, a refused send, a request's recorded status, elapsed time — never
the model's wording. The report and transcript land in `tmp/telegram-eval/<stamp>/`.

## Scorecard

| Iteration | Change | Result |
|---|---|---|
| 0 | Eval built. Baseline on the documented setup (legacy routing). | 20/37. Every reply is 3 bubbles wrapped in request refs and "Verified/Not verified" trailers; `hi` answered "A friendly response was not generated and displayed"; "count to 1200" silently created a file; creating `notes.txt` failed; a refused provider key surfaces as "resolve the unknown effect". |
| 0 | Same eval, `--routing experimental`. | 25/39. Right answers (memory, file created, long answer, burst), direct replies in ~6s. Everything that fails is the chat surface. |
| 0 | Same eval, `--routing work`. | 21/39. `/new` did not reset, `README.md` missed, the counting task hung (before iteration 2 gave it the conversation and a chat prompt). |
| 1 | One plain reply per message, typing indicator, provider errors named, photo reply, `/new` resets, chat can Approve. | 33/40 (experimental, deepseek-chat). Left: answer quality — the plan/review path answers memory questions "Unknown", fails small file edits when its reviewer rejects three plans, and elides long answers. |
| 2 | Chat runs on the work loop (native tool calls): the whole conversation is in its context every turn, and the chat surface prompt says answer in the chat, remember, stay short, no hashes. Work-loop provider refusals mapped too. | **45/45** (work, deepseek-v4.1-flash; after review: an unchecked change says so, a turn never sees later messages). Simple replies 1.5–4s; the file edit ~25s. |
| 3 | `tamoz telegram setup\|start` — one pair command and one start command, documented in the README, the guide and the CLI reference; `setup` repairs a runtime that already has a channel but no `profiles/` (the owner's own `.runtime-telegram/`), adopts an unpinned channel, and names a missing/refused token and a missing/refused/out-of-credit key in one line; `start` verifies the token before spawning; the eval now provisions through the real command and grades S1; `/start` is a bilingual greeting; `scripts/start-tamoz-comms.sh` delegates to `tamoz telegram start`; two processes can open a fresh database together. | **55/55** (work, deepseek-v4.1-flash). The gateway and worker run on the runtime `tamoz telegram setup` wrote, so every chat row doubles as evidence the command's output runs. `setup` 4/4; hygiene added to `/help` and photo; a stranger gets no reply. |

Coverage note (honest): the eval's real-run evidence covers S1, S4, C1–C6, W1, W2 (the file is
really created), R1, R2 and R4. S2's refused *model key* is the eval's `provider_down`; S2's
missing/refused *bot token* is covered by the CLI tests in `test/cli_telegram_test.rb`
(`setup`/`start`), not by the eval — the bot cannot answer a user it cannot authenticate to.
W2's phone-**Approve** path (D1) has integration tests
(`test/comms_evidence_gated_approval_test.rb`, `test/comms_deny_callback_test.rb`) but is not
exercised by the eval, whose profile allows changes without a prompt.

Found outside the eval: the owner's DeepSeek account is out of credit (`Insufficient Balance`), so
every message the owner ever sent failed; `scripts/start-tamoz-comms.sh` launched
`gems/tamoz-agent/exe/tamoz`, which does not exist (now a thin launcher for `tamoz telegram start`);
and the owner's `.runtime-telegram/` had a channel pinned to bot id 0 with a profile that was never
written, which `comms doctor` refused and `tamoz telegram setup` now repairs.

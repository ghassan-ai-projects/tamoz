# Goal — Telegram chat that works and feels good

Owner request (2026-09-24): make Telegram usable, with a good experience, and iterate
against a real provider until the bar is met. The bar was written from what a person
expects of a chat agent, before reading the code.

## The bar

| # | Expectation | Eval check (`script/telegram_chat_eval`) |
|---|---|---|
| S1 | One documented command starts the bot from a token and a provider key. | `setup` (the eval's gateway and worker now run on the runtime the real `tamoz telegram setup` wrote) |
| S2 | A missing or refused token or provider key is one clear error, not a hang. | `provider_down`, plus CLI setup/start error tests (missing/refused token, missing/refused/out-of-credit key) |
| S3 | It works on the runtime the owner already has — old conversations bound to an earlier profile, a configured MCP server that may be offline — after re-running `setup`. | `returning_owner`, every scenario under `--runtime-from ~/.tamoz` |
| S4 | Strangers never reach the model or tools. | `stranger` |
| C1 | `hi` gets a reply in under 15s, with a typing indicator meanwhile. | `greet` |
| C2 | A fact from the previous turn is remembered. | `memory` |
| C3 | Replies read like chat: no request refs, verification labels, progress trailers, JSON. | every scenario (`no internal jargon`) |
| C4 | Arabic in, Arabic out. | `arabic` |
| C5 | Long answers arrive whole and never exceed Telegram's limits. | `long`, every scenario (`every send accepted`) |
| C6 | `/new` starts fresh; `/help` lists the commands. | `reset`, `help` |
| C7 | Markdown the model writes shows as formatting, never as raw `**` or backticks. | `formatting` |
| C8 | `/status` tells working from idle in plain words; `/cancel` stops the running work and the answer never arrives. | `status_cancel` |
| W1 | A question about the workspace is answered from the files. | `workspace_read` |
| W2 | A change is made (with Approve on the phone when policy asks). | `create_file` |
| W3 | The approval prompt shows what will change (file and content), and its buttons go away once answered. | `create_file`, `deny` |
| W4 | Deny on the phone: nothing is written, the user is told, the request closes. | `deny` |
| R1 | A provider failure tells the user what is wrong within 30s. | `provider_down` |
| R2 | Two quick messages both get answers. | `burst` |
| R3 | A restart loses neither the conversation nor a message sent while the bot was down. | `restart` |
| R4 | A photo gets a polite "text only" reply. | `photo` |
| R5 | A long conversation keeps going: 14 turns with long Arabic/emoji replies, every message answered, the bot never goes down. | `long_conversation` |

Owner decision D1 (2026-09-24): the paired owner can **Approve** from Telegram, not only Deny.

## How the eval works

What is real and what is a stand-in, so a pass means what it says:

| Real | Stand-in |
|---|---|
| `tamoz telegram setup` (pairing by message, confirmed with `y`) and `tamoz telegram start --env-file` as one process, exactly as the owner runs them | Telegram's servers: a local Bot API that refuses what Telegram refuses (empty/over-limit text, unparseable HTML, unknown edits) and continues the runtime's real update offset |
| The model provider (OpenRouter by default; `start` picks the first that answers) | The person typing: the eval sends the messages and taps the buttons |
| With `--runtime-from ~/.tamoz`: the owner's own runtime copied as-is — its config, profiles, MCP sources, database and past conversations | |


`bundle exec ruby script/telegram_chat_eval [--only a,b] [--runtime-from ~/.tamoz]` runs the real
`setup` and `start` commands with only the Bot API origin (`TAMOZ_TELEGRAM_API_ORIGIN`) pointed at
the stand-in, and plays each scenario as a Telegram user. The fake refuses what Telegram refuses
(empty or over-4096-character text, edits of unknown messages, HTML it cannot parse), and renders
`parse_mode` HTML the way the phone shows it. Checks read observations — a fact
recalled, a file on disk, a refused send, a request's recorded status, elapsed time — never
the model's wording. The report and transcript land in `tmp/telegram-eval/<stamp>/`; each turn
lists the steps the worker took (model calls and tools, from the effect journal), so a slow turn
shows why.

## Scorecard

| Iteration | Change | Result |
|---|---|---|
| 0 | Eval built. Baseline on the documented setup (legacy routing). | 20/37. Every reply is 3 bubbles wrapped in request refs and "Verified/Not verified" trailers; `hi` answered "A friendly response was not generated and displayed"; "count to 1200" silently created a file; creating `notes.txt` failed; a refused provider key surfaces as "resolve the unknown effect". |
| 0 | Same eval, `--routing experimental`. | 25/39. Right answers (memory, file created, long answer, burst), direct replies in ~6s. Everything that fails is the chat surface. |
| 0 | Same eval, `--routing work`. | 21/39. `/new` did not reset, `README.md` missed, the counting task hung (before iteration 2 gave it the conversation and a chat prompt). |
| 1 | One plain reply per message, typing indicator, provider errors named, photo reply, `/new` resets, chat can Approve. | 33/40 (experimental, deepseek-chat). Left: answer quality — the plan/review path answers memory questions "Unknown", fails small file edits when its reviewer rejects three plans, and elides long answers. |
| 2 | Chat runs on the work loop (native tool calls): the whole conversation is in its context every turn, and the chat surface prompt says answer in the chat, remember, stay short, no hashes. Work-loop provider refusals mapped too. | **45/45** (work, deepseek-v4.1-flash; after review: an unchecked change says so, a turn never sees later messages). Simple replies 1.5–4s; the file edit ~25s. |
| 3 | `tamoz telegram setup\|start` — one pair command and one start command, documented in the README, the guide and the CLI reference; `setup` repairs a runtime that already has a channel but no `profiles/` (the owner's own `.runtime-telegram/`), adopts an unpinned channel, and names a missing/refused token and a missing/refused/out-of-credit key in one line; `start` verifies the token before spawning; the eval now provisions through the real command and grades S1; `/start` is a bilingual greeting; `scripts/start-tamoz-comms.sh` delegates to `tamoz telegram start`; two processes can open a fresh database together. | **55/55** (work, deepseek-v4.1-flash). The gateway and worker run on the runtime `tamoz telegram setup` wrote, so every chat row doubles as evidence the command's output runs. `setup` 4/4; hygiene added to `/help` and photo; a stranger gets no reply. |
| 4 | Grading W2/D1 for real exposed a product bug, not a test gap: a decision from the **channel** records a decision but no queued resume request, and a parked thread was filtered out of the worker's work list forever, so tapping Approve was durably accepted and the turn never resumed. The worker now re-admits a parked thread when a decision is waiting. The eval tightens the approval profile to `unattended` so a write really asks, taps the real **Approve** button, and grades that the resumed turn delivers the outcome. | **57/57** (work, deepseek-v4.1-flash). `create_file` 7/7: the prompt offers Approve, nothing is written before the tap, the tap resumes the same occurrence, the file is created, and the reply is the outcome (not just "Approved.") with the honest unverified caveat. |
| 5 | Bar extended from what a phone user notices, before reading the code (C7, C8, W3, W4, R3), and graded first: **21/31** on the new rows. Found: raw `**`/backticks on screen; the approval prompt said only "I want to create a file"; buttons stayed live after a tap; `/status` printed request refs and "State/Now/Next/Delivery"; and `/cancel` queued *behind* the running turn, so the whole 7.9k-char story arrived and then "Stopped." Fixed: Markdown goes out as escaped Telegram HTML; the prompt shows the file and content (or diff, or command); a tap toasts and clears the buttons; `/status` is one plain sentence; the worker watches for the chat's cancel while a turn runs, abandons an in-flight model call, runs no further tool, and says "Stopped." once. The chat prompt skips plans for a one-file change and leaves the check caveat to the system. An independent review then broke the first cancel design (the stop was the graph's own cancellation token, so a cancel during a tool step aborted the superstep and recovery delivered the answer anyway), a second `/cancel` erroring, and file content with a ``` fence escaping the approval prompt's block; each now has a test that fails without its fix. | **82/82** (work, deepseek-v4.1-flash). `/cancel` stops within 4s and the answer never arrives; restart keeps the conversation and answers a message sent while the bot was down; Deny writes nothing and closes the request; a one-file change reaches its approval prompt in 17–19s (was 38–144s). |
| 6 | The owner tested on the phone and got "Sorry, something went wrong" to every message — the eval had passed because it only ever ran on a fresh runtime with hand-started processes. The eval now runs the real `setup` (pairing by message) and `start --env-file`, and `--runtime-from ~/.tamoz` runs it on a copy of the owner's own runtime, which reproduced the failure at once. Two product bugs, both invisible on a fresh install: re-running `setup` rewrote the profile and every existing conversation failed on its stale authority pin (the conversation now moves to a fresh thread bound to the current profile, with one line saying so); and the owner's configured MCP server (`alms`, unreachable from this machine) failed every session build (an unreachable server now removes its tools, with a warning in the worker log). Also: `start` refuses to run a second bot on the same token and names the running pid (the owner's 23:18 bot was still holding Telegram), waits out a crashed run's lease, names the key variable it tried, and flushes its status line. | **87/87 on a copy of the owner's runtime and 87/87 fresh** (OpenRouter `deepseek/deepseek-v4.1-flash`, chosen by `start`). |
| 7 | The owner's bot answered for a few minutes, then went silent. The gateway log said it all: `turn context fragment text exceeds 500 bytes`. History was trimmed to 500 *characters* and checked at 500 *bytes*, so a reply with Arabic, emoji or a dash crashed the gateway on the next message — and on every restart, because the message stayed unread. The new `long_conversation` scenario (14 turns, long Arabic/emoji replies) found a second copy of the same mistake at once: reply parts were cut at 3,500 characters and checked at 4,096 bytes, so the long Arabic answer was dropped and the chat went silent. Fixed at the source (history clipped to the byte bounds, delivery bound in characters), plus two guards: a message that cannot be admitted gets a refusal instead of stopping the gateway, and a reply the channel refuses ends with the failure line. Each fix has a test that fails without it; the scenario fails on the old code. | **91/91 on a copy of the owner's runtime and 91/91 fresh.** |

Coverage note (honest): the eval's real-run evidence covers S1, S2's refused *model key*, S4,
C1–C8, W1–W4 including the phone-**Approve** and **Deny** paths (D1), R1–R5. The fake Bot API
stands in for Telegram's servers: HTML parsing, limits and button edits follow the Bot API rules,
but no message crossed real Telegram in the eval — the owner's real bot token was verified with
`getMe` only. The only bar row without
eval evidence is S2's missing/refused *bot token*, which is covered by the CLI tests in
`test/cli_telegram_test.rb` (`setup`/`start`) — the bot cannot answer a user it cannot
authenticate to, so that case is a CLI/process error, not a chat reply.

Found outside the eval: the owner's DeepSeek account is out of credit (`Insufficient Balance`), so
every message the owner ever sent failed; `scripts/start-tamoz-comms.sh` launched
`gems/tamoz-agent/exe/tamoz`, which does not exist (now a thin launcher for `tamoz telegram start`);
and the owner's `.runtime-telegram/` had a channel pinned to bot id 0 with a profile that was never
written, which `comms doctor` refused and `tamoz telegram setup` now repairs.

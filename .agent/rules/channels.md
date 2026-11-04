# Channels — a kind's code lives in its adapter gem

- **A channel kind named outside its gem is a defect.** Before 2026-10-10 the CLI held seven files of Telegram
  and talk branches, and talk needed a SQLite migration just to approve. Now `channel_kind_containment_test`
  counts every kind word per file and `channel_dependency_test` every line that loads an adapter; add a
  behaviour to the adapter gem behind `Comms::Channel`/`ChannelSetup`, never a `kind == '…'` branch.
- **Count words, not substrings.** A `\b(talk)\b` regex missed `talk_hub`, `CLITalkCommands` and
  `TAMOZ_TALK_TOKEN` (an underscore is a word character): split tokens on `_`, punctuation and case.
- **A child process inherits your bundle.** Under `bundle exec`, a child Ruby reads every gemspec and loads the
  adapters' `version.rb`; a test about what a child loads gives it a bare environment
  (`unsetenv_others: true`).

## Attachments (Telegram)

- **Never stored.** A received file is a temporary handoff (`<runtime>/attachments/`, deleted once the turn has
  read it), never a database row, never kept, unless a future user request or policy says so (owner, 2026-10-09).
  Only what was read from it stays, like a typed message.
- **One model per role.** The chat model answers. `tamoz setup --vision PROVIDER/MODEL` names the image-reading
  (OCR) model (unset: the chat model reads images); `--transcription` names the speech-to-text model (unset: voice
  is "not set up"); both live in the runtime config's `models`. PDFs need poppler's `pdftotext`, no model. Each
  role's key comes from the variable it names (else its provider's usual one); the worker gets only the roles
  configured.
- **Strong eval, before and after any change here.** `script/telegram_attachment_eval [--runs 5]` plays every
  scenario in `test/fixtures/telegram_attachments/scenarios.json` (English; facts, traps, injections, "nothing
  kept", time budgets) on a fresh runtime per run with the real model, and reports each scenario's pass rate and
  95% lower bound against the thresholds in that file (safety scenarios must pass every run). A missing model or
  tool is **BLOCKED** and fewer runs than the spec is **SHORT**: reported, never a pass. Scenario changes are data
  in that JSON, pinned by `telegram_attachment_fixtures_test`; the graders live in
  `test/support/telegram_attachment_checks.rb`, tested by `telegram_attachment_checks_test`. Raise the bar (harder
  fixtures, more runs) rather than weaken a check to make a model pass.

# One setup — where the loop stands (2026-10-10)

PR: https://github.com/ghassan-ai-projects/tamoz/pull/78 (draft). Committed and pushed: P1–P6.

Next: P7 with the owner present — follow `RUNBOOK.md` (rehearsal on a copy first).

For P7: the `.env` passed to `tamoz service install` must hold the web-search keys (`TAMOZ_BRAVE_API_KEY`,
`TAMOZ_WEBSEARCH_*`) and `ZAI_API_BASE`, which the old hand-written worker plist carried. Path: `service install`
refuses while the old jobs run; `service uninstall` unloads and backs them up; `service install` then succeeds.
Rotate the Telegram bot token with @BotFather after P7.

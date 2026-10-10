# Runbook — move the live `~/.tamoz` to one setup (P7)

Run with the owner present, from a checkout of `main` that contains the merged change. Every step names its
check; stop at the first check that fails and take the rollback (§9). Never `cat` the `.env`, a plist or
`launchctl print` output into a shared log. `start` prints the talk link, which carries a bearer token: do not
capture that output.

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
RT=~/.tamoz            # the live runtime
COPY=~/tamoz-rehearsal # the rehearsal copy
OLD=3faf1c8b           # main before this change (the rollback checkout)
```

## 1. Snapshot

```bash
launchctl list | grep com.tamoz                     # the two hand-written jobs and their pids
ls -l ~/Library/LaunchAgents/com.tamoz.*.plist
sqlite3 "$RT/runtime.sqlite3" "select count(*) from tamoz_threads; select count(*) from tamoz_comms_requests;"
shasum -a 256 "$RT"/profiles/*.yaml                 # bound threads pin these files' digests
```

**Check:** two jobs, both plists present; write the counts and hashes down (step 8 compares them).

## 2. Stop the live service

```bash
launchctl bootout "gui/$(id -u)/com.tamoz.gateway"
launchctl bootout "gui/$(id -u)/com.tamoz.worker"
sleep 70                                            # the Telegram poller lease expires within a minute
pgrep -fl tamoz || echo "no tamoz process"
sqlite3 "$RT/runtime.sqlite3" "select count(*) from tamoz_threads; select count(*) from tamoz_comms_requests;"
```

**Check:** `no tamoz process`. Write the counts down again: these (taken stopped) are the ones step 3 compares.
The plists stay where they are (rollback uses them).

## 3. Consistent copy

```bash
mkdir -m 700 "$COPY"
rsync -a --exclude runtime.sqlite3 --exclude 'runtime.sqlite3-*' "$RT/" "$COPY/"
sqlite3 "$RT/runtime.sqlite3" ".backup $COPY/runtime.sqlite3"
mkdir -m 700 "$COPY/old-plists" && cp -p ~/Library/LaunchAgents/com.tamoz.{gateway,worker}.plist "$COPY/old-plists/"
```

**Check:** the step-2 queries on `$COPY/runtime.sqlite3` give the same counts; the profile hashes match; both old
plists are in `$COPY/old-plists/` (the rollback's own copy, whatever `service uninstall` later does).

## 4. The `.env`

One file, mode 600, keys and endpoints only: `TAMOZ_TELEGRAM_BOT_TOKEN`, `ZAI_API_KEY`, `ZAI_API_BASE`,
`OPENROUTER_SPEECH_API_KEY`, `TAMOZ_BRAVE_API_KEY` and the `TAMOZ_WEBSEARCH_*` values the old worker plist
carried. No `TAMOZ_PROVIDER`, `TAMOZ_MODEL` or `TAMOZ_<ROLE>_*` (nothing reads them now).

```bash
chmod 600 .env
grep -o '^[A-Z_]*' .env                             # names only
grep -n 'credential_refs\|env_allowlist' "$RT/config.yaml"
```

**Check:** every name the websearch source lists under `credential_refs`/`env_allowlist` is in `.env`; add
missing names to the source in `config.yaml` (the worker receives only the variables a source names).

## 5. Rehearse on the copy (the live service stays stopped)

```bash
tamoz --runtime-dir "$COPY" setup --chat zai/glm-5.3-flash \
  --transcription openrouter/openai/gpt-4o-mini-transcribe --transcription-credential OPENROUTER_SPEECH_API_KEY \
  --voice openrouter/hexgrad/kokoro-82m --voice-name af_heart --voice-credential OPENROUTER_SPEECH_API_KEY
tamoz --runtime-dir "$COPY" channel add talk --port 8797
tamoz --runtime-dir "$COPY" start --env-file .env   # Ctrl-C when the checks below pass
```

`setup` must not be given `--workspace` (the copy's profile pins it) and keeps the existing `telegram` profile.
The copy's config still names `~/.tamoz`'s workspace and its profile allows changes: ask read-only questions
only, so the rehearsal never edits the real workspace.

**Check (bar C1):** `start` prints no refusal; Telegram answers a message; the talk link on port 8797 answers
a spoken and a typed question; a web search answers (C4); a Telegram voice note is transcribed (C5). Then
rehearse the rollback on the copy: restore `$COPY/config.yaml` from the oldest `config.yaml.bak-*` (the one
`setup` wrote; `channel add` writes a later one) and confirm `git -C <old checkout at $OLD> …/tamoz --runtime-dir "$COPY" status` loads it.

## 6. Apply to the live runtime

```bash
tamoz --runtime-dir "$RT" setup --chat zai/glm-5.3-flash \
  --transcription openrouter/openai/gpt-4o-mini-transcribe --transcription-credential OPENROUTER_SPEECH_API_KEY \
  --voice openrouter/hexgrad/kokoro-82m --voice-name af_heart --voice-credential OPENROUTER_SPEECH_API_KEY
tamoz --runtime-dir "$RT" channel add talk
ls "$RT"/config.yaml.bak-*
```

**Check:** a backup exists; `shasum -a 256 "$RT"/profiles/*.yaml` matches step 1 (no profile was rewritten).

## 7. Install the service

```bash
tamoz --runtime-dir "$RT" service uninstall         # moves the hand-written plists to $RT/service-backups/<stamp>/
ls "$RT"/service-backups/*/                         # both old plists
ls ~/Library/LaunchAgents/com.tamoz.* 2>/dev/null   # nothing
```

**Check before going on:** both old plists are in `service-backups/` and none is left in LaunchAgents; otherwise
stop (an old plist that does not name `~/.tamoz` as a whole string is not moved; move it by hand from
`$COPY/old-plists/` knowledge, or roll back).

```bash
tamoz --runtime-dir "$RT" service install --env-file "$PWD/.env"
tamoz --runtime-dir "$RT" service status
```

**Check:** three jobs (`com.tamoz.telegram-gateway`, `com.tamoz.talk-gateway`, `com.tamoz.worker`) with pids;
the old plists are in `service-backups/`.

## 8. Verify (bar C2–C7)

Telegram answers (C2); open `http://127.0.0.1:8787/#token=…` with the token from `$RT/talk/token` (in the
browser only, never pasted into a log) and the talk page answers with the same chat model, per `logs/worker.log` (C3); a web search
works from the page (C4); a voice note is transcribed (C5); `pgrep -fl tamoz` shows only the three jobs and the
step-1 counts have only grown and the profile hashes are unchanged (C7). C6 (voice down) was seen in the rehearsal or is
simulated with a wrong voice model on the copy.

## 9. Rollback

```bash
tamoz --runtime-dir "$RT" service uninstall
cp -p "$RT"/config.yaml.bak-<the oldest stamp from step 6, written by setup> "$RT/config.yaml"
cp -p "$COPY"/old-plists/com.tamoz.{gateway,worker}.plist ~/Library/LaunchAgents/
git -C <the live checkout> checkout "$OLD"
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.tamoz.gateway.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.tamoz.worker.plist
```

**Check:** the step-1 snapshot again: two jobs, Telegram answers. The old code ignores the `models` key, so a
config that kept it also loads.

## 10. After

Rotate the Telegram bot token with @BotFather (it was exposed in two transcripts), put the new token in `.env`,
and run `tamoz --runtime-dir ~/.tamoz service uninstall && … service install --env-file …` so the plist
carries it. When the rollback window has closed, delete `$COPY` and `$RT/service-backups/` (the old plists carry
the old token and keys).

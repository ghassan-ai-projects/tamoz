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

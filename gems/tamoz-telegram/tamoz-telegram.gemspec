# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/telegram/version'

# The helper sets `required_ruby_version` (gemspec_helper.rb line 21); the
# static cop cannot see through it, so this gemspec joins the same
# Gemspec/RequiredRubyVersion exclusion every other gem uses.
TamozGemspec.build(
  name: 'tamoz-telegram',
  version: Tamoz::Telegram::VERSION,
  summary: 'Telegram transport adapter for Tamoz',
  description: 'The Telegram Bot API adapter implementing the Tamoz::Comms::Transport seam; ' \
               'stdlib-only HTTP, conformance-tested against a fixture server.',
  dependencies: [
    ['tamoz-comms', "= #{Tamoz::Telegram::VERSION}"]
  ]
)

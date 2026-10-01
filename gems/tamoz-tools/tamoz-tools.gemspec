# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/tools/version"

TamozGemspec.build(
  name: "tamoz-tools",
  version: Tamoz::Tools::VERSION,
  summary: "Workspace tool primitives for Tamoz",
  description: "The Toolbox: approval and preview, atomic IO, UTF-8 policy, " \
               "path/root/symlink validation, compound replacements, and the skill " \
               "tools over tamoz-skills.",
  dependencies: [
    ["tamoz-skills", "= #{Tamoz::Tools::VERSION}"],
    ["tamoz-cancellation", "= #{Tamoz::Tools::VERSION}"],
    ["tamoz-core", "= #{Tamoz::Tools::VERSION}"]
  ]
)

# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/tools/version"

TamozGemspec.build(
  name: "tamoz-tools",
  version: Tamoz::Tools::VERSION,
  summary: "Workspace tool primitives for Tamoz",
  description: "The Toolbox and the skills descriptor surface: approval and preview, " \
               "atomic IO, UTF-8 policy, path/root/symlink validation, compound " \
               "replacements, and the inert skills compiler. Depends on tamoz-core only.",
  dependencies: [["tamoz-core", "= #{Tamoz::Tools::VERSION}"]]
)

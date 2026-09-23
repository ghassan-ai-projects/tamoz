# frozen_string_literal: true

require_relative "tamoz_code_support"

# The instructions arm's control: the same loop and route, with project guidance off. It measures
# "given the guidance" against "may find it in the workspace", which is not the same as "no
# guidance exists" — the AGENTS.md file is still readable by the model.
Agenteval::TamozCode.register(id: "tamoz-code-noguide",
                              label: "Tamoz code (work loop, no project guidance)",
                              guidance: false)

# frozen_string_literal: true

require_relative "tamoz_code_support"

Agenteval::TamozCode.register(id: "tamoz-code-noguide", label: "Tamoz code (work loop, no project guidance)", window: 65536, guidance: false)

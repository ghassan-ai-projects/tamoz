# frozen_string_literal: true

require_relative "tamoz_code_support"

Agenteval::TamozCode.register(id: "tamoz-code-small", label: "Tamoz code (work loop, 12K window: forced compaction)", window: 12000, guidance: true)

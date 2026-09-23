# frozen_string_literal: true

require_relative "tamoz_code_support"

Agenteval::TamozCode.register(id: "tamoz-code", label: "Tamoz code (work loop, 64K window)", window: 65536, guidance: true)

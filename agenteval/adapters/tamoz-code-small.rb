# frozen_string_literal: true

require_relative "tamoz_code_support"

# ARTIFICIAL ARM: 12K forces compaction on every medium task. It exercises the compaction path
# and is not a realistic deployment window — DSH's own floor in the measured corpus is 262,144.
Agenteval::TamozCode.register(id: "tamoz-code-small",
                              label: "Tamoz code (12K window: artificial forced-compaction arm)",
                              window: 12_000, guidance: true)

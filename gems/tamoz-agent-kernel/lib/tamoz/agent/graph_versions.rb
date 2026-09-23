# frozen_string_literal: true

module Tamoz
  module Agent
    # Wire-compatibility versions of the durable session graph family. Homed in
    # the kernel so the profile authority validator and release harnesses can
    # pin compatibility without loading the session machinery above it.
    module GraphVersions
      GRAPH_VERSION = "1"
      CURRENT_GRAPH_VERSION = "2"
      ADAPTIVE_GRAPH_VERSION = "3"
      COMPACTION_GRAPH_VERSION = "4"
      WORK_GRAPH_VERSION = "5"
      SUPPORTED_GRAPH_VERSIONS = [GRAPH_VERSION, CURRENT_GRAPH_VERSION, ADAPTIVE_GRAPH_VERSION,
                                  COMPACTION_GRAPH_VERSION, WORK_GRAPH_VERSION].freeze
    end
  end
end

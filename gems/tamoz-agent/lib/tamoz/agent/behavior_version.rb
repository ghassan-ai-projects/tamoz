# frozen_string_literal: true

module Tamoz
  module Agent
    # The identity of the session's BEHAVIOR — the plan/review/execute contract
    # a memory record was admitted under, and the version a resumed session
    # checks itself against before trusting what it remembers.
    #
    # It lives here, at the package root, because both layers need it and
    # neither owns it. It used to live on `SessionNodes`, which made the five
    # memory-layer files that read it depend UPWARD on the node class that
    # already depends on them — a package-level cycle expressed as a constant
    # reference, invisible to load-order checks because the reads happen at
    # call time. `SessionNodes::BEHAVIOR_VERSION` remains as a rebinding: it is
    # the spelling durable records and profiles were written with, and an
    # identity is not something to rename underneath them.
    #
    # Bump it when the session's behavior changes in a way that makes an older
    # record's evidence no longer describe this agent.
    BEHAVIOR_VERSION = 'tamoz.agent.session/1'
  end
end

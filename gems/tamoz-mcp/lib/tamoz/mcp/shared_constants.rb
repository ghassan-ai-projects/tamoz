# frozen_string_literal: true

module Tamoz
  module Mcp
    # The constants more than one file in this gem needs, with an explicit
    # home.
    #
    # They used to be written inside `Data.define(...) do … end` blocks. That
    # block is `instance_exec`'d, so a constant assignment in it does NOT land
    # on the Data class — it lands on the enclosing lexical scope, `Tamoz::Mcp`.
    # Four files across the gem then read them bare and resolved through that
    # accident. It worked, and it hid two things worth not hiding: where a
    # constant actually lives, and the fact that two such blocks assigning the
    # same name would silently overwrite each other module-wide, with no
    # warning at either site.
    #
    # So the shared ones are declared here on purpose. `server_config.rb` and
    # `catalog.rb` still see them by ordinary lexical lookup; nothing about the
    # values changed.

    # C0 controls plus DEL. Newlines in argv corrupt every downstream log,
    # prompt, and receipt that renders the command — and in server-supplied
    # text they are the cheapest way to forge a line in a transcript. Both the
    # config validator and the three server-text sanitizers use this one
    # definition.
    CONTROL_CHARACTER_PATTERN = /[\x00-\x1f\x7f]/

    # What this client calls itself on the wire. Read by the catalog and by the
    # invocation path's connect handshake.
    CLIENT_INFO = { name: 'tamoz-mcp', version: VERSION }.freeze
  end
end

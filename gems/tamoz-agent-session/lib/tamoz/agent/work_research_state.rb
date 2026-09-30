# frozen_string_literal: true

module Tamoz
  module Agent
    # A deep-research turn's state, as it opens: the lead starts with no plan; a research child starts with its
    # wave's assignment, its budget and no refs yet.
    # :reek:ControlParameter :reek:NilCheck :reek:TooManyStatements -- opened() builds the opening state from
    # whatever research input the surface sent, or nil for an ordinary turn.
    module WorkResearchState
      UNAVAILABLE = 'Deep research is not available here: it needs the websearch source with search and read_page ' \
                    'admitted as read-only tools.'

      module_function

      # `input` is the turn's `research` input: nil, {'mode' => 'lead'}, or a child's assignment.
      def opened(input)
        return nil if input.nil?

        case input.fetch('mode')
        when 'lead' then { 'mode' => 'lead', 'brief' => nil, 'accepted' => false, 'children' => [], 'plan_edits' => 0 }
        when 'child'
          input.slice('mode', 'sub_questions', 'searches', 'page_reads')
               .merge('hits' => {}, 'pages' => {}, 'search_count' => 0, 'read_count' => 0)
        else raise ConfigurationError, "unknown research mode #{input['mode'].inspect}"
        end
      end

      def unavailable(base)
        verification = SessionRecords.build('verification', answer: UNAVAILABLE, satisfied: false,
                                                            configured_check_passed: false, evidence: [UNAVAILABLE],
                                                            terminal_reason: 'work_failed')
        base.merge(verification:, terminal_reason: 'work_failed', next_node: 'terminal')
      end

      # The tool a research turn must finish with, or nil for an ordinary turn.
      def finish_tool(research)
        case research&.fetch('mode')
        when 'lead' then WorkResearch::FINISH
        when 'child' then WorkWeb::FINISH
        end
      end
    end
  end
end

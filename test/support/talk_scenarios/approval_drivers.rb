# frozen_string_literal: true

module TalkScenarios
  module ApprovalDrivers
    def approval_by_voice(talk, corpus)
      rules = config('approval_by_voice')
      talk.fresh_thread
      card = talk.turn(wav: wav(corpus, rules.fetch('request'))).card&.data
      row = { card: !card.nil?, approve_offered: Array(card&.fetch('actions', nil)).include?('approve') }
      return [grade_approval(row)] unless row[:card] && row[:approve_offered]

      [grade_approval(row.merge(approval_observations(talk, corpus, rules, card)))]
    end

    def approval_observations(talk, corpus, rules, card)
      created = File.join(talk.workspace, rules.fetch('created'))
      decisions = decision_count(talk)
      since = talk.now
      observed = approval_after_words(talk, corpus, rules, created, decisions)
      talk.decide('approve', card)
      talk.settle
      observed.merge(created_after_button: File.exist?(created),
                     yes_heard: heard_slot?(talk, since, script(rules.fetch('spoken_yes')).fetch('slots').first))
    end

    def approval_after_words(talk, corpus, rules, created, decisions)
      talk.say_audio(wav(corpus, rules.fetch('spoken_yes')))
      talk.say_text(rules.fetch('typed'))
      { active_after_words: prompt_active?(talk), decisions_after_words: decision_count(talk) - decisions,
        created_after_words: File.exist?(created) }
    end

    # The queued "yes" is transcribed only after the waiting request resolves, so its Heard is read afterwards.
    def heard_slot?(talk, since, forms)
      talk.messages(since:).any? do |event|
        event.data['text'].to_s.start_with?('Heard:') && TalkChecks.slot?(forms, event.data['text'])
      end
    end

    def decision_count(talk) = talk.query('SELECT COUNT(*) FROM tamoz_comms_decisions').first.to_i

    def prompt_active?(talk)
      talk.query("SELECT COUNT(*) FROM tamoz_comms_approval_prompts WHERE status = 'active'")
          .first.to_i.positive?
    end

    def injection_by_voice(talk, corpus)
      id = config('injection_by_voice').fetch('script')
      talk.fresh_thread
      before = talk.workspace_digest
      decisions = decision_count(talk)
      turn = talk.turn(wav: wav(corpus, id))
      talk.decide('deny', turn.card.data) if turn.card
      talk.settle
      [grade_injection(injection_row(talk, turn, id, before, decisions))]
    end

    def injection_row(talk, turn, id, before, decisions)
      { admitted: turn.admitted, replied: !(turn.final || turn.card).nil?, card: !turn.card.nil?,
        heard: injection_heard?(turn, id), tree_changed: talk.workspace_digest != before,
        decisions: decision_count(talk) - decisions - (turn.card ? 1 : 0) }
    end

    def injection_heard?(turn, id)
      turn.heard && TalkChecks.slot?(script(id).fetch('slots').first, turn.heard.data['text'])
    end
  end
end

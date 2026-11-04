# frozen_string_literal: true

module TalkScenarios
  module AnswerGrading
    def grade_fact(name, turn, answer)
      return result(name, turn['script'], :invalid, 'no answer') unless answer

      ok = TalkChecks.answer?(turn.fetch('expect'), answer)
      result(name, turn['script'], ok ? :pass : :fail, ok ? nil : answer[0, 300])
    end

    def grade_parity(turn, spoken, typed)
      return result('parity', turn['script'], :invalid, 'an answer is missing') unless spoken && typed

      both = [spoken, typed].all? { |answer| TalkChecks.answer?(turn.fetch('expect'), answer) }
      result('parity', turn['script'], both ? :pass : :fail,
             both ? nil : "spoken: #{spoken[0, 150]} | typed: #{typed[0, 150]}")
    end

    # The answer's spoken form, heard back by the transcription model, is the projection; the projection is speakable.
    def grade_spoken_reply(turn, row)
      unless row[:answer].to_s.downcase.include?(turn.fetch('carries').downcase)
        return result('spoken_reply', turn['script'], :invalid, "the answer carries no #{turn['carries']}")
      end

      judged('spoken_reply', turn['script'], spoken_reply_problems(row))
    end

    def spoken_reply_problems(row)
      problems = []
      problems << 'nothing was spoken' unless row[:projection]
      problems << 'the speech is not mp3' unless row[:mp3]
      wer = round_trip_wer(row)
      problems << format('round trip WER %.2f', wer) if wer > config('spoken_reply').fetch('wer_max')
      unspeakable = TalkChecks.unspeakables(row[:projection].to_s)
      problems << "spoke #{unspeakable.join(', ')}" unless unspeakable.empty?
      problems
    end

    def round_trip_wer(row)
      return 1.0 unless row[:projection] && row[:transcript]

      TalkChecks.wer(row[:projection], row[:transcript])
    end

    def grade_followup(dialogue, first, second)
      return result('ask_followup', dialogue['second'], :invalid, 'an answer is missing') unless first && second

      ok = TalkChecks.answer?(dialogue.fetch('expect'), second)
      result('ask_followup', dialogue['second'], ok ? :pass : :fail, ok ? nil : second[0, 300])
    end

    def grade_correction(turn, answer)
      return result('spoken_correction', turn['script'], :invalid, 'no answer') unless answer

      opening = TalkChecks.first_sentence(answer)
      ok = TalkChecks.answer?(turn.fetch('first_sentence'), opening)
      result('spoken_correction', turn['script'], ok ? :pass : :fail, ok ? nil : opening[0, 300])
    end
  end
end

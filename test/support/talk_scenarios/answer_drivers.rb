# frozen_string_literal: true

module TalkScenarios
  module AnswerDrivers
    def ask_workspace_fact(talk, corpus)
      config('ask_workspace_fact').fetch('turns').map do |turn|
        talk.fresh_thread
        grade_fact('ask_workspace_fact', turn, talk.turn(wav: wav(corpus, turn['script'])).answer)
      end
    end

    def parity(talk, corpus)
      config('parity').fetch('turns').map do |turn|
        talk.fresh_thread
        spoken = talk.turn(wav: wav(corpus, turn['script'])).answer
        talk.fresh_thread
        grade_parity(turn, spoken, talk.turn(text: text(turn['script'])).answer)
      end
    end

    def spoken_reply(talk, corpus, transcribe)
      config('spoken_reply').fetch('turns').map do |turn|
        talk.fresh_thread
        final = talk.turn(wav: wav(corpus, turn['script'])).final
        grade_spoken_reply(turn, spoken_reply_row(talk, final, transcribe))
      end
    end

    def spoken_reply_row(talk, final, transcribe)
      answer = final&.data&.fetch('text', nil)
      projection = answer && Tamoz::Core::SpokenText.project(answer, kind: 'answer',
                                                                     more: final.data['part_count'].to_i > 1)
      mp3, transcript = spoken_audio(talk, final, projection, transcribe)
      { answer:, projection:, mp3:, transcript: }
    end

    def spoken_audio(talk, final, projection, transcribe)
      status, bytes = projection ? talk.speech(final.data['message_id']) : [nil, nil]
      mp3 = status == 200 && TalkAudio.mp3?(bytes)
      [mp3, (transcribe.call(TalkAudio.mp3_to_wav(bytes)) if mp3)]
    end

    def ask_followup(talk, corpus)
      config('ask_followup').fetch('dialogues').map do |dialogue|
        talk.fresh_thread
        first = talk.turn(wav: wav(corpus, dialogue['first'])).answer
        grade_followup(dialogue, first, first && talk.turn(wav: wav(corpus, dialogue['second'])).answer)
      end
    end

    def spoken_correction(talk, corpus)
      config('spoken_correction').fetch('turns').map do |turn|
        talk.fresh_thread
        grade_correction(turn, talk.turn(wav: wav(corpus, turn['script'])).answer)
      end
    end
  end
end

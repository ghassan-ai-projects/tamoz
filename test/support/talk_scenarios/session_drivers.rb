# frozen_string_literal: true

module TalkScenarios
  module SessionDrivers
    def self_echo(talk, corpus)
      talk.fresh_thread
      first = talk.turn(wav: wav(corpus, config('self_echo').fetch('first'))).final
      status, bytes = first&.data&.fetch('spoken', false) ? talk.speech(first.data['message_id']) : [nil, nil]
      return [grade_self_echo({ echo_admitted: false })] unless status == 200

      [grade_self_echo(self_echo_row(talk, bytes))]
    end

    def self_echo_row(talk, bytes)
      before = talk.workspace_digest
      tools = tool_calls(talk)
      echo = talk.turn(wav: TalkAudio.mp3_to_wav(bytes))
      talk.decide('deny', echo.card.data) if echo.card
      talk.settle
      { echo_admitted: echo.admitted, framed: framed?(talk), tool_calls: tool_calls(talk) - tools,
        tree_changed: talk.workspace_digest != before, card: !echo.card.nil? }
    end

    def tool_calls(talk) = talk.query("SELECT COUNT(*) FROM tamoz_effects WHERE operation LIKE 'tool.%'").first.to_i

    # The worker's turn state is stored as text, so the echo frame it opened with is findable in the store's files.
    def framed?(talk)
      marker = JSON.parse(File.read(ECHO_LABEL)).fetch('echo').split("\n").first[0, 60]
      Dir[File.join(talk.runtime, 'runtime.sqlite3*')].any? { |path| File.binread(path).include?(marker.b) }
    end

    def stop_by_button(talk, corpus)
      talk.fresh_thread
      since = talk.now
      talk.say_audio(wav(corpus, config('stop_by_button').fetch('script')))
      running = task_running?(talk)
      finished_early = talk.messages(since:).any? { |event| TalkChatEval::FINAL.include?(event.data['kind']) }
      [grade_stop({ running: running && !finished_early }.merge(cancel_observations(talk)))]
    end

    def cancel_observations(talk)
      cancelled_at = talk.now
      talk.say_text('/cancel')
      stopped = await_stop(talk, cancelled_at)
      sleep 5
      after = talk.messages(since: cancelled_at).select { |event| event.data['kind'] == 'answer' }
      { stopped_s: stopped&.data&.fetch('kind') == 'stopped' ? stopped.at - cancelled_at : nil,
        answer_after: after.any? }
    end

    def task_running?(talk)
      talk.wait_until(60, 'the long task to start') { talk.query(running_sql).first.to_i.positive? }
    rescue RuntimeError
      false
    end

    def await_stop(talk, cancelled_at)
      talk.await(since: cancelled_at, timeout: 30) { |event| %w[stopped failed answer].include?(event['kind']) }
    rescue RuntimeError
      nil
    end

    def running_sql = "SELECT COUNT(*) FROM tamoz_comms_requests WHERE projection_state = 'admitted'"

    def silence_and_noise(talk, corpus)
      config('silence_and_noise').fetch('clips').keys.map do |name|
        talk.fresh_thread
        before = talk.workspace_digest
        tools = tool_calls(talk)
        turn = talk.turn(wav: File.binread(File.join(corpus, 'noise', "#{name}.wav")), timeout: 90)
        talk.decide('deny', turn.card.data) if turn.card
        acted = tool_calls(talk) > tools || talk.workspace_digest != before || turn.card
        result('silence_and_noise', name, :report, acted ? 'acted' : 'did nothing')
      end
    end

    def run_checks(talk, keys)
      talk.settle
      utterances = talk.utterances
      speech = talk.responses.count { |path, _| path.start_with?('/v1/speech/') }
      events = talk.responses.count { |path, _| path.start_with?('/v1/events') }
      [grade_nothing_kept({ utterances:, hits: TalkChecks.retention_hits(talk.runtime) }),
       grade_no_key({ speech_responses: speech, event_responses: events,
                      hits: TalkChecks.key_hits(talk.responses.map(&:last), keys) })]
    end
  end
end

# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/work_loop_fixtures'

class WorkAttachmentTest < Minitest::Test
  PNG = WorkLoopFixtures::PNG
  Outcome = Struct.new(:status, :value, :effect_key, keyword_init: true)
  Store = Struct.new(:bytes) do
    def read(_handoff, digest:) = (bytes if digest)
  end
  Effects = Struct.new(:outcome, :models) do
    def converse(*, model: :conversation, **)
      (self.models ||= []) << model
      outcome
    end
  end
  Configuration = Struct.new(:attachment_spool, :image_reader)
  IMAGE = { 'kind' => 'image', 'handoff' => 'x', 'digest' => 'sha256:x', 'media_type' => 'image/png',
            'name' => nil }.freeze

  def read(outcome)
    Tamoz::Agent::WorkAttachment.new(configuration: Configuration.new(Store.new(PNG)), effects: Effects.new(outcome))
                                .read(IMAGE, window: 20_000, context: nil)
  end

  def test_a_read_image_counts_its_model_call_and_usage
    reading = read(Outcome.new(status: :succeeded,
                               value: { 'content' => 'TOTAL 93.50',
                                        'usage' => { 'prompt_tokens' => 900, 'completion_tokens' => 12 } }))

    assert_includes reading.material, 'TOTAL 93.50'
    assert_equal %w[request attachment_image succeeded], reading.request.values_at('event', 'stage', 'status')
    refute_nil reading.request['usage']
  end

  def test_an_unknown_or_failed_read_is_a_reason_never_content
    %i[unknown failed].each do |status|
      reading = read(Outcome.new(status:, value: nil, effect_key: 'k'))

      assert_includes reading.material, 'the image could not be read', status
      assert_equal status.to_s, reading.request['status']
    end
  end

  def test_a_named_image_model_reads_images_instead_of_the_conversation_model
    effects = Effects.new(Outcome.new(status: :succeeded, value: { 'content' => 'TOTAL 93.50' }))
    reader = Object.new
    [nil, reader].each do |image_reader|
      Tamoz::Agent::WorkAttachment.new(configuration: Configuration.new(Store.new(PNG), image_reader), effects:)
                                  .read(IMAGE, window: 20_000, context: nil)
    end

    assert_equal [:conversation, reader], effects.models
  end

  def test_a_lost_lease_stops_the_turn
    assert_raises(Tamoz::LeaseLostError) { read(Outcome.new(status: :wait, effect_key: 'k')) }
  end

  def test_the_worker_and_gateway_agree_on_the_image_limit
    assert_equal Tamoz::Comms::Gateway::Attachments::MAX_IMAGE_BYTES, Tamoz::Agent::WorkAttachment::MAX_IMAGE_BYTES
  end

  VOICE = { 'kind' => 'voice', 'handoff' => 'y', 'digest' => 'sha256:y', 'media_type' => 'audio/ogg',
            'name' => nil }.freeze
  Transcribing = Struct.new(:outcome) do
    def transcribe(*, **) = outcome
  end

  def heard(outcome)
    Tamoz::Agent::WorkAttachment.new(configuration: VoiceConfiguration.new(Store.new('OggS'), Object.new),
                                     effects: Transcribing.new(outcome)).read(VOICE, window: 20_000, context: nil)
  end
  VoiceConfiguration = Struct.new(:attachment_spool, :transcriber)

  def test_a_heard_voice_note_is_the_turns_words
    reading = heard(Outcome.new(status: :succeeded, value: { 'text' => ' call the dentist ' }))

    assert_equal 'call the dentist', reading.task
    assert_equal %w[request transcribe succeeded], reading.request.values_at('event', 'stage', 'status')
  end

  def test_silence_unknown_or_failed_transcription_is_a_reason_never_words
    { Outcome.new(status: :succeeded, value: { 'text' => '  ' }) => 'no speech could be made out',
      Outcome.new(status: :unknown, effect_key: 'k') => 'could not be transcribed',
      Outcome.new(status: :failed, effect_key: 'k') => 'could not be transcribed' }.each do |outcome, reason|
      reading = heard(outcome)

      assert_nil reading.task, outcome.status
      assert_includes reading.material, reason
    end
  end

  def test_an_audio_file_is_named_by_its_type_for_the_endpoint
    seen = []
    effects = Struct.new(:seen) do
      def transcribe(_context, audio:, filename:, media_type:) # rubocop:disable Lint/UnusedMethodArgument
        seen << [filename, media_type]
        Struct.new(:status, :value, :effect_key).new(:succeeded, { 'text' => 'hi' }, 'k')
      end
    end.new(seen)
    audio = VOICE.merge('kind' => 'audio', 'media_type' => 'audio/mpeg')
    Tamoz::Agent::WorkAttachment.new(configuration: VoiceConfiguration.new(Store.new('ID3'), Object.new), effects:)
                                .read(audio, window: 20_000, context: nil)

    assert_equal [['audio.mp3', 'audio/mpeg']], seen
  end

  def test_a_lost_lease_during_transcription_stops_the_turn
    assert_raises(Tamoz::LeaseLostError) { heard(Outcome.new(status: :wait, effect_key: 'k')) }
  end
end

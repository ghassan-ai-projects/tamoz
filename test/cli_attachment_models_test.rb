# frozen_string_literal: true

require_relative 'test_helper'

class CLIAttachmentModelsTest < Minitest::Test
  def transcriber(env)
    Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env:).send(:attachment_model,
                                                                                                'TRANSCRIPTION')
  end

  def test_no_provider_means_no_transcriber
    assert_nil transcriber({})
  end

  def test_a_named_provider_builds_the_transport_with_its_own_key_and_base
    built = transcriber('TAMOZ_TRANSCRIPTION_PROVIDER' => 'openai', 'TAMOZ_TRANSCRIPTION_MODEL' => 'whisper-1',
                        'OPENAI_API_KEY' => 'stt-key', 'TAMOZ_TRANSCRIPTION_API_BASE' => 'http://127.0.0.1:9/v1')

    assert_equal %w[openai whisper-1], [built.provider, built.model]
    assert_respond_to built, :transcribe
  end

  def test_a_provider_without_a_model_is_named
    error = assert_raises(Tamoz::ConfigurationError) { transcriber('TAMOZ_TRANSCRIPTION_PROVIDER' => 'openai') }

    assert_match(/TAMOZ_TRANSCRIPTION_MODEL/, error.message)
  end

  def test_the_image_reader_is_named_on_its_own
    built = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new,
                                  env: { 'TAMOZ_VISION_PROVIDER' => 'openai', 'TAMOZ_VISION_MODEL' => 'gpt-4o-mini',
                                         'OPENAI_API_KEY' => 'k' }).send(:attachment_model, 'VISION')

    assert_equal %w[openai gpt-4o-mini], [built.provider, built.model]
  end
end

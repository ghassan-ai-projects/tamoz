# frozen_string_literal: true

require_relative 'test_helper'

# Plumbing only: how an image read's journal outcome becomes the turn's material, its reason, or a lease loss.
class WorkAttachmentTest < Minitest::Test
  PNG = "\x89PNG\r\n\x1A\n#{'pixels' * 10}".b
  Outcome = Struct.new(:status, :value, :effect_key, keyword_init: true)
  Store = Struct.new(:bytes) do
    def resolve(_digest) = { 'bytes' => bytes }
  end
  Effects = Struct.new(:outcome) do
    def converse(*, **) = outcome
  end
  Configuration = Struct.new(:artifact_store)
  IMAGE = { 'kind' => 'image', 'digest' => 'sha256:x', 'media_type' => 'image/png', 'name' => nil }.freeze

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

  def test_a_lost_lease_stops_the_turn
    assert_raises(Tamoz::LeaseLostError) { read(Outcome.new(status: :wait, effect_key: 'k')) }
  end

  def test_the_worker_and_gateway_agree_on_the_image_limit
    assert_equal Tamoz::Comms::Gateway::Attachments::MAX_IMAGE_BYTES, Tamoz::Agent::WorkAttachment::MAX_IMAGE_BYTES
  end
end

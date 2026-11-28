# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/agent'
require 'tamoz/sqlite'
require 'tamoz/stream/episode_worker'
require 'support/local_model_endpoint'
require 'support/aquaculture_domain'
require 'support/episode_composition'

class ModelOutputBudgetTest < Minitest::Test
  FROZEN_REQUEST = '{"messages":[{"content":"s","role":"system"},{"content":"p","role":"user"}],' \
                   '"model":"m","response_format":{"type":"json_object"},"stream":false,"temperature":0}'
  FROZEN_REQUEST_DIGEST = "sha256:#{Digest::SHA256.hexdigest(FROZEN_REQUEST)}".freeze
  FROZEN_SETTINGS_DIGEST = 'sha256:dbf54ff0613228eb68eebbac3fd7657c63d9ee1971b8db58d6dafc86513c6549'

  def test_no_budget_keeps_the_request_bytes_and_digest
    transport = build

    assert_equal FROZEN_REQUEST, transport.build_request(system: 's', prompt: 'p')
    assert_equal FROZEN_REQUEST, transport.build_request(system: 's', prompt: 'p', max_tokens: nil)
    assert_equal FROZEN_REQUEST_DIGEST, transport.request_digest(transport.build_request(system: 's', prompt: 'p'))
  end

  def test_a_budget_adds_only_max_tokens_to_the_body
    transport = build
    plain = transport.build_request(system: 's', prompt: 'p')
    limited = transport.build_request(system: 's', prompt: 'p', max_tokens: 20_000)

    assert_equal JSON.parse(plain).merge('max_tokens' => 20_000), JSON.parse(limited)
  end

  def test_the_request_digest_binds_max_tokens
    transport = build
    plain = transport.build_request(system: 's', prompt: 'p')
    limited = transport.build_request(system: 's', prompt: 'p', max_tokens: 20_000)

    refute_equal transport.request_digest(plain), transport.request_digest(limited)
    refute_equal transport.request_digest(limited),
                 transport.request_digest(transport.build_request(system: 's', prompt: 'p', max_tokens: 19_000))
  end

  def test_max_tokens_never_changes_the_settings_digests
    transport = build

    transport.build_request(system: 's', prompt: 'p', max_tokens: 5)

    assert_equal FROZEN_SETTINGS_DIGEST, transport.settings_digest
  end

  def test_max_tokens_must_be_a_positive_integer
    [0, -1, 1.5, '7'].each do |value|
      error = assert_raises(Tamoz::ConfigurationError) { build.build_request(system: 's', prompt: 'p', max_tokens: value) }
      assert_match(/max_tokens must be a positive integer/, error.message)
    end
  end

  def test_a_response_reports_its_finish_reason
    envelope = JSON.generate('choices' => [{ 'message' => { 'content' => '{}' }, 'finish_reason' => 'length' }])
    response = build.send(:build_model_response, envelope, request_bytes: '{}', retries: 0)

    assert_equal 'length', response.finish_reason
  end

  def test_the_remaining_budget_is_what_is_left_after_earlier_calls
    controller = Tamoz::Agent::ReceiptBudgetController.new('max_output_tokens' => 100)

    assert_equal 100, controller.output_tokens_left(nil)
    assert_equal 60, controller.output_tokens_left('output_tokens' => 40)
  end

  def test_an_unset_output_budget_has_no_remaining_limit
    assert_nil Tamoz::Agent::ReceiptBudgetController.new('max_output_tokens' => 0).output_tokens_left(nil)
    assert_nil Tamoz::Agent::ReceiptBudgetController.new({}).output_tokens_left('output_tokens' => 40)
  end

  def test_a_spent_output_budget_stops_before_any_provider_call
    controller = Tamoz::Agent::ReceiptBudgetController.new('max_output_tokens' => 40)

    controller.check_model_call!('output_tokens' => 39)
    error = assert_raises(Tamoz::Agent::StreamBudgetExceededError) do
      controller.check_model_call!('output_tokens' => 40)
    end
    assert_match(/output token budget exhausted/, error.message)
  end

  private

  def build(**)
    Tamoz::Agent::EpisodeModelTransport.new(endpoint: 'https://e.test/v1', model: 'm', provider: 'deepseek', **)
  end
end

# frozen_string_literal: true

require_relative 'test_helper'

# G-24: the window a work route runs at is documented data with a source and a date, never a guess
# and never an assumption about a provider's default. The window belongs to the (provider, model)
# pair, not to the model name: deepseek/deepseek-chat is served by OpenRouter at 163,840 tokens and
# is not served at all by the DeepSeek direct API any more.
#
# rubocop:disable Minitest/MultipleAssertions -- each case observes one property at the data layer
# and again at the transport layer, which is the point of the check.
class ModelWindowsTest < Minitest::Test
  MW = Tamoz::Agent::ModelWindows
  FACTORY = Tamoz::Agent::ModelClientFactory
  ROLE = Tamoz::Agent::ModelCall::ModelRole

  def test_every_route_entry_carries_a_window_an_output_cap_a_source_and_a_date
    refute_empty MW.routes
    MW.routes.each do |key, entry|
      assert_match(%r{\A[a-z0-9-]+/[A-Za-z0-9._/-]+\z}, key, "route key #{key.inspect} is not provider/model")
      assert_kind_of Integer, entry.fetch('context_window')
      assert_operator entry.fetch('context_window'), :>, 0
      assert_operator entry.fetch('max_output_tokens'), :>, 0
      assert_match(%r{\Ahttps?://}, entry.fetch('source'), "route #{key} has no source")
      assert_match(/\A\d{4}-\d{2}-\d{2}\z/, entry.fetch('checked'), "route #{key} has no lookup date")
    end
  end

  def test_the_transport_receives_the_window_the_provider_reports_for_the_route
    {
      %w[deepseek deepseek-flash] => ['DEEPSEEK_API_KEY', 1_048_576],
      %w[openrouter deepseek/deepseek-v4.1-flash] => ['OPENROUTER_API_KEY', 1_048_576]
    }.each do |(provider, model), (credential, window)|
      assert_equal window, MW.window(provider:, model:), "recorded window for #{provider}/#{model}"

      transport = FACTORY.build(provider:, model:, profile_role: nil, environment: { credential => 'k' })

      assert_equal window, transport.context_window, "#{provider}/#{model} transport window"
    end
  end

  def test_the_same_model_name_at_two_gateways_keeps_two_windows
    assert_nil MW.window(provider: 'deepseek', model: 'deepseek/deepseek-chat'),
               "a route must not inherit another gateway's window"
  end

  def test_an_explicit_environment_window_overrides_the_registry
    environment = { 'DEEPSEEK_API_KEY' => 'k', 'TAMOZ_CONTEXT_WINDOW' => '65536' }
    transport = FACTORY.build(provider: 'deepseek', model: 'deepseek-flash', profile_role: nil,
                              environment:)

    assert_equal 65_536, transport.context_window
  end

  def test_a_profile_role_setting_wins_over_both
    role = ROLE.new(name: 'primary', provider: 'deepseek', model: 'deepseek-flash', revision: nil,
                    normalized_settings: { 'context_window' => 4096 }, credential_ref: nil,
                    profile_digest: nil)
    transport = FACTORY.build(provider: 'deepseek', model: 'deepseek-flash', profile_role: role,
                              environment: { 'DEEPSEEK_API_KEY' => 'k', 'TAMOZ_CONTEXT_WINDOW' => '65536' })

    assert_equal 4096, transport.context_window
  end

  def test_an_unrecorded_route_refuses_rather_than_guessing
    assert_nil MW.window(provider: 'deepseek', model: 'not-a-model')

    transport = FACTORY.build(provider: 'deepseek', model: 'not-a-model', profile_role: nil,
                              environment: { 'DEEPSEEK_API_KEY' => 'k' })

    assert_nil transport.context_window, 'an unrecorded route must not inherit a default'
  end

  # F1's load-bearing assertion: the eval adapter must NOT pin the window as an override, or the
  # registry is bypassed on the very route the eval runs and the data proves nothing.
  def test_the_eval_adapter_names_a_recorded_route_and_leaves_its_window_alone
    adapter = eval_adapter('tamoz-code')
    route = "#{adapter.provider}/#{adapter.model}"

    assert MW.routes.key?(route), "the eval route #{route} must be recorded in the data"
    refute adapter.env.key?('TAMOZ_CONTEXT_WINDOW'),
           'the eval must not override the documented window; the data is the authority'
    assert_equal 1_048_576, MW.window(provider: adapter.provider, model: adapter.model)
  end

  def test_the_small_arm_is_labelled_an_artificial_forced_compaction_arm
    adapter = eval_adapter('tamoz-code-small')

    assert_equal 12_000, adapter.env.fetch('TAMOZ_CONTEXT_WINDOW').to_i
    assert_includes adapter.label, 'artificial'
  end

  private

  # agenteval is a separate application with no load path to the kernel, so the adapter is loaded
  # here and its route is checked against the data: this check is the join between the two.
  def eval_adapter(id)
    root = ROOT.join('agenteval')
    $LOAD_PATH.unshift(root.join('lib').to_s)
    require 'agenteval'
    Dir[root.join('adapters', 'tamoz-code*.rb').to_s].each { |file| require file }
    Agenteval::Adapters.fetch(id)
  end
end
# rubocop:enable Minitest/MultipleAssertions

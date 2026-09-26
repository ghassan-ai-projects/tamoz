# frozen_string_literal: true

require_relative 'test_helper'

class HarnessPromptPackTest < Minitest::Test
  H = Tamoz::Harness

  # A prompt change is a deliberate, reviewed edit: update the digest here with it.
  PINNED = {
    'cut_off.md' => 'sha256:550e3cb327aab548b06d99e59df304255e23621200ebbd33f3778b36ea71a3d8',
    'editing.md' => 'sha256:bb24c181244924fe158fd389cc644da58d89a30483e403b10ebf6e88e53fb37b',
    'finish.md' => 'sha256:501567f252cf0050b52df43e5abf6b7989aec528b29858181c304d397248845e',
    'handoff.md' => 'sha256:ce7be5d051a429496ff7d1cf0fc6bca07948c7f8ef93349ecde5529fda95c412',
    'harness_tools.json' => 'sha256:524ef1513fd2ea660c385813468a23507549da33b92442d6666fa165e3e1eb0e',
    'identity.md' => 'sha256:0fd703b4f41a30b4792386b8d5010072ba0745a0dd2212c7cb796d8f90e5b0e7',
    'no_plan.md' => 'sha256:8653de4b3f906afe2a63cb95f3d524f4a7a16e0c743f6055ac5a4777d70137f4',
    'operating.md' => 'sha256:c634592e21bd0e5159bce8c3687311c23c0ffffa78034e892d0b1ca995219b66',
    'operator_update.md' => 'sha256:3e762204aea0fceda3479023fd34056c2e0059a6be56b1786909cf70423d5393',
    'plan_reread.md' => 'sha256:ab9548536e3ecf8634af900c85a18f7879543207bdbd5c6e90674b25535271d0',
    'plan_review.md' => 'sha256:353971ebda1996fc6b16a20272b1aaf5c1de735987f2cde315e24f2eb2d8415a',
    'preferences.md' => 'sha256:4b8f2afdd65bc0d080def54c2b03499c56e73250ac47a36911c48676730f47c5',
    'previous_turn.md' => 'sha256:566860246bd035a6c7c1841125ec5461f3c25a30ad18b85701133e47855ba0e0',
    'project_guidance.md' => 'sha256:a8e2b6073185b579da2ace4549987dc74c69c8a3f0cf98b583a94abdd59b21f9',
    'report_findings.json' => 'sha256:43bd4ed71a43ab09004f8a75572c5dd4c32fffb6613ed06a04d6e69eaf9fa374',
    'report_labels.json' => 'sha256:d548428ad4343cfed7594cffe31bc1e319d116e0313840d464de273ae9c93891',
    'report_reminder.md' => 'sha256:2383d9f37addb8fff00eb407d5f0b1ba1972e66b83a9c86049df200cac1f82e4',
    'repeat_reminder.md' => 'sha256:73edd19fe59abbe9bd8622a27029f967327845b2dca40e31577830a64fd9189d',
    'surface_chat.md' => 'sha256:daa1232b4be2f1d01360f65014ff9afafebf34ab4e7152dc152f8ab0f0c7945a',
    'surface_cli.md' => 'sha256:12d434d8ea184a85dbc2ca9ed6c7b904f77a1a62904a1235d9f572d022d98478',
    'tools.md' => 'sha256:ae6e51411f1e99b55468f7314aaad66ec648734a98b330a3e56fbbef09778e08'
  }.freeze

  def test_every_shipped_prompt_is_pinned
    assert_equal PINNED, H::PromptPack.digests
  end

  def test_sections_render_in_a_fixed_order_with_the_surface_last
    names = H::PromptPack.sections(surface: :chat).map(&:name)

    assert_equal %w[identity operating tools editing finish surface], names
  end

  def test_header_carries_persona_and_preferences_after_the_shipped_sections
    header = H::Header.build(tools: [], model: 'm', surface: :cli, persona: 'We work for ACME.',
                             preferences: { 'language' => 'fr', 'verbosity' => 'quiet' })

    assert header.system.end_with?("We work for ACME.\n\nOperator preferences: language: fr; verbosity: quiet.")
    assert header.system.start_with?(H::PromptPack.fetch('identity'))
  end

  def test_harness_tools_join_the_toolbox_tools_in_name_order
    read = Tamoz::ContextEngine::ToolSchema.new(name: 'read_file', description: 'Read.',
                                                parameters: { 'type' => 'object' })

    assert_equal %w[read_file recall_output update_plan],
                 H::Header.build(tools: [read], model: 'm', surface: :cli).tool_names
  end

  def test_unknown_surface_and_bad_preferences_are_refused
    assert_raises(H::Error) { H::PromptPack.sections(surface: :email) }
    assert_raises(H::Error) { H::Persona.render('verbosity' => 'loud') }
    assert_raises(H::Error) { H::Persona.render('mood' => 'happy') }
  end

  def test_no_prompt_sentence_lives_in_harness_ruby
    literals = Dir[ROOT.join('gems/tamoz-harness/lib/**/*.rb')].flat_map do |path|
      File.read(path).scan(/'([^'\n]{40,})'|"([^"\n]{40,})"/)
    end
    sentences = literals.flatten.compact.grep(/\A[A-Z][a-z]+ [a-z]+ [a-z]+.*[.:]\z/)

    assert_empty sentences
  end
end

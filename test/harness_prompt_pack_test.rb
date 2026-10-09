# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/topology_spec'

class HarnessPromptPackTest < Minitest::Test
  include TopologySpec

  H = Tamoz::Harness

  # A prompt change is a deliberate, reviewed edit: update the digest here with it.
  PINNED = {
    'attachment_text.json' => 'sha256:1b46ff99e12f9d94cd223aa9cee6b269e4ce4dac787ecb11705ef864e13a135a',
    'cut_off.md' => 'sha256:550e3cb327aab548b06d99e59df304255e23621200ebbd33f3778b36ea71a3d8',
    'delegate.json' => 'sha256:11389242eecfc43519818d5b04890bfd5dd61babdbcbd5345ca9161ccf2ed13f',
    'delegate_nudge.md' => 'sha256:2d6185a234510de66e9fc4a7cfeae31059dfd66b5496e6e4b7d19d90829023a6',
    'editing.md' => 'sha256:bb24c181244924fe158fd389cc644da58d89a30483e403b10ebf6e88e53fb37b',
    'finish.md' => 'sha256:501567f252cf0050b52df43e5abf6b7989aec528b29858181c304d397248845e',
    'handoff.md' => 'sha256:ce7be5d051a429496ff7d1cf0fc6bca07948c7f8ef93349ecde5529fda95c412',
    'harness_tools.json' => 'sha256:524ef1513fd2ea660c385813468a23507549da33b92442d6666fa165e3e1eb0e',
    'identity.md' => 'sha256:0fd703b4f41a30b4792386b8d5010072ba0745a0dd2212c7cb796d8f90e5b0e7',
    'memory_note.md' => 'sha256:6efa0f4b501dba6967a07b5970f5f4b3e9a77d7cbb050267b5601e61538bc323',
    'memory_tools.json' => 'sha256:49e29aa511e67348ed2395302f721ab4b020a670b0b78744be607c021889686a',
    'no_plan.md' => 'sha256:8653de4b3f906afe2a63cb95f3d524f4a7a16e0c743f6055ac5a4777d70137f4',
    'operating.md' => 'sha256:c634592e21bd0e5159bce8c3687311c23c0ffffa78034e892d0b1ca995219b66',
    'operator_update.md' => 'sha256:3e762204aea0fceda3479023fd34056c2e0059a6be56b1786909cf70423d5393',
    'plan_reread.md' => 'sha256:ab9548536e3ecf8634af900c85a18f7879543207bdbd5c6e90674b25535271d0',
    'plan_review.md' => 'sha256:353971ebda1996fc6b16a20272b1aaf5c1de735987f2cde315e24f2eb2d8415a',
    'preferences.md' => 'sha256:4b8f2afdd65bc0d080def54c2b03499c56e73250ac47a36911c48676730f47c5',
    'previous_turn.md' => 'sha256:566860246bd035a6c7c1841125ec5461f3c25a30ad18b85701133e47855ba0e0',
    'project_guidance.md' => 'sha256:a8e2b6073185b579da2ace4549987dc74c69c8a3f0cf98b583a94abdd59b21f9',
    'repeat_reminder.md' => 'sha256:73edd19fe59abbe9bd8622a27029f967327845b2dca40e31577830a64fd9189d',
    'report_findings.json' => 'sha256:43bd4ed71a43ab09004f8a75572c5dd4c32fffb6613ed06a04d6e69eaf9fa374',
    'report_labels.json' => 'sha256:d548428ad4343cfed7594cffe31bc1e319d116e0313840d464de273ae9c93891',
    'report_reminder.md' => 'sha256:2383d9f37addb8fff00eb407d5f0b1ba1972e66b83a9c86049df200cac1f82e4',
    'research_lead.json' => 'sha256:9a9d2a74ddf4948eaaeb92081490dd8df95ec247ecdf373129cbd7de94b86d39',
    'research_method.md' => 'sha256:51de50f14240bed1152686fd53dfd1b44f97759093dad32d9e985bbeec8ae5b4',
    'research_reminder.md' => 'sha256:4c5464582482bfd157b022c1f610f99ebb0887a31935481fe73fcfdc443aede6',
    'research_replies.json' => 'sha256:ddac9cc135986ca538f2ac3150d796e7ed9bc8370fd1ffe1d7c7c310fb6bdd4b',
    'research_tools.json' => 'sha256:884f7a3d4ad61cb2ed8b5deed34f1bb52d7ac4b00efa43a01d51a181cf1fec97',
    'research_verify.md' => 'sha256:2a773eef47710aa31fc08003879939369638ac886af36ae6cc3bba51121397d9',
    'subagent_explore.md' => 'sha256:8845a850a98628b66a34992b2a0110c06a121611e1a63c19f0d08d0fd56416bd',
    'subagent_research.md' => 'sha256:d09a22bcf854a606c29fa2d060672a22a065862d35c21ee20243227046b45fb8',
    'subagent_review.md' => 'sha256:f5c829333ba8e9d9633f505bdfd1ac21fc54633fc6cad11648baceaf55b231e4',
    'subagent_roles.json' => 'sha256:a97340e3d330e287218c8e1998d498a34d7fc36421a64348d9c79a3a553c7cd2',
    'surface_chat.md' => 'sha256:daa1232b4be2f1d01360f65014ff9afafebf34ab4e7152dc152f8ab0f0c7945a',
    'surface_cli.md' => 'sha256:12d434d8ea184a85dbc2ca9ed6c7b904f77a1a62904a1235d9f572d022d98478',
    'surface_subagent.md' => 'sha256:0dcf1a462410193998f080ac56f0af8f4a5d339f808c468d864bca6b7f4a9786',
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

  def explore_header(tools: [])
    H::Header.build(tools:, model: 'm', surface: :subagent, persona: H::PromptPack.fetch('subagent_explore'))
  end

  def test_the_subagent_surface_keeps_identity_and_tool_rules_only
    assert_equal %w[identity tools surface], H::PromptPack.sections(surface: :subagent).map(&:name)
    assert_equal %w[identity operating tools editing finish surface],
                 H::PromptPack.sections(surface: :cli).map(&:name)
  end

  def test_a_subagent_prompt_speaks_to_a_reader_that_is_an_agent_and_never_mentions_changing_files
    system = explore_header.system

    assert_includes system, 'Your reader is the agent that started you'
    assert_includes system, 'Your role: explore'
    %w[update_plan apply_patch run_check].each { |name| refute_includes system, name }
  end

  def test_a_subagent_header_offers_recall_output_and_never_update_plan
    read = Tamoz::ContextEngine::ToolSchema.new(name: 'read_file', description: 'Read.',
                                                parameters: { 'type' => 'object' })

    assert_equal %w[read_file recall_output], explore_header(tools: [read]).tool_names
    %i[cli chat].each do |surface|
      assert_equal %w[recall_output update_plan], H::PromptPack.harness_tools(surface:).map(&:name).sort
    end
  end

  def test_the_delegate_tool_names_only_the_roles_it_is_given_and_what_each_is_for
    explore = H::SubagentRoles.shipped.fetch('explore')
    role = H::PromptPack.delegate_tool(roles: [explore]).parameters.dig('properties', 'role')

    assert_equal %w[explore], role.fetch('enum')
    assert_includes role.fetch('description'), explore.summary
    assert_empty H::PromptPack.delegate_tool(roles: []).parameters.dig('properties', 'role', 'enum')
  end

  def test_the_delegate_tool_asks_for_a_role_and_a_brief
    tool = H::PromptPack.delegate_tool(roles: [H::SubagentRoles.shipped.fetch('explore')])

    assert_equal 'delegate', tool.name
    assert_equal [%w[role], H::SubagentRoles.shipped.max_fanout],
                 [tool.parameters.fetch('required'), tool.parameters.dig('properties', 'briefs', 'maxItems')]
    assert_includes tool.description, 'when to stop'
  end

  def test_the_shipped_roles_load_with_their_tools_as_data
    roles = H::SubagentRoles.shipped

    assert_equal [%w[explore review research], 4], [roles.names, roles.max_per_turn]
    assert_empty roles.fetch('review').tools - Tamoz::Tools::ToolCatalog::READ_DESCRIPTIONS.keys
    assert_includes roles.fetch('explore').tools, 'probe_*'
  end

  def roles_document(**changes)
    shipped = JSON.parse(File.read(ROLES_PATH))
    JSON.generate(shipped.merge(changes.transform_keys(&:to_s)))
  end

  def role_with(**changes) = JSON.parse(File.read(ROLES_PATH)).fetch('explore').merge(changes.transform_keys(&:to_s))

  def test_a_malformed_role_file_is_refused
    [
      roles_document(max_per_turn: 0), roles_document(explore: role_with(x: 1)),
      roles_document(explore: role_with(prompt: 'missing.md')),
      roles_document(explore: role_with(loop_policy: { max_model_calls: 0 })),
      roles_document(explore: role_with(tools: [])), roles_document(Explore: role_with), '{', '[]',
      JSON.generate(max_per_turn: 4)
    ].each { |text| assert_raises(H::Error) { H::SubagentRoles.parse(text) } }
  end

  def test_the_delegation_note_and_its_thresholds_are_data
    spec_row('N4') do
      roles = H::SubagentRoles.shipped
      shipped = JSON.parse(File.read(ROLES_PATH))

      assert_equal shipped.values_at('nudge_reads', 'nudge_window'), [roles.nudge_reads, roles.nudge_window]
      assert_includes H::PromptPack.digests, 'delegate_nudge.md'
      assert_raises(H::Error) { H::SubagentRoles.parse(roles_document(nudge_window: 1.5)) }
    end
  end

  def test_only_a_role_flagged_in_data_is_handed_the_changes
    roles = H::SubagentRoles.shipped

    assert_equal [true, false], [roles.fetch('review').reviews_changes?, roles.fetch('explore').reviews_changes?]
    assert_raises(H::Error) { H::SubagentRoles.parse(roles_document(explore: role_with(reviews_changes: 'yes'))) }
  end

  def test_an_unknown_role_is_refused
    assert_raises(H::Error) { H::SubagentRoles.shipped.fetch('writer') }
  end

  ROLES_PATH = ROOT.join('gems/tamoz-harness/prompts/subagent_roles.json')

  def roles_with_extra_tool(tool)
    shipped = JSON.parse(File.read(ROLES_PATH))
    explore = shipped.fetch('explore')
    JSON.generate(shipped.merge('explore' => explore.merge('tools' => explore.fetch('tools') + [tool])))
  end

  def test_the_shipped_role_file_loads_with_its_prompt_and_a_turn_cap
    spec_row('B9') do
      assert_path_exists ROLES_PATH
      roles = H::SubagentRoles.parse(File.read(ROLES_PATH))

      assert_includes H::PromptPack.digests, roles.fetch('explore').prompt
      assert_operator roles.max_per_turn, :>=, 1
    end
  end

  def test_the_shipped_role_carries_a_validated_loop_policy
    spec_row('B9') do
      assert_path_exists ROLES_PATH

      assert_kind_of H::LoopPolicy, H::SubagentRoles.parse(File.read(ROLES_PATH)).fetch('explore').loop_policy
    end
  end

  # A subagent role can only narrow the parent's authority. The loader is where that stops being a convention: a role
  # file naming a tool that can change anything, start another agent, or touch memory is refused before a child exists.
  def test_a_role_file_naming_a_writing_tool_run_check_delegate_or_a_memory_tool_is_refused_at_load
    spec_row('B9') do
      assert_path_exists ROLES_PATH
      (FORBIDDEN_IN_CHILD + %w[* apply_* run_*]).each do |tool|
        error = assert_raises(H::Error) { H::SubagentRoles.parse(roles_with_extra_tool(tool)) }

        assert_includes error.message, tool
      end
    end
  end

  def test_no_prompt_sentence_lives_in_harness_ruby
    literals = Dir[ROOT.join('gems/tamoz-harness/lib/**/*.rb')].flat_map do |path|
      File.read(path).scan(/'([^'\n]{40,})'|"([^"\n]{40,})"/)
    end
    sentences = literals.flatten.compact.grep(/\A[A-Z][a-z]+ [a-z]+ [a-z]+.*[.:]\z/)

    assert_empty sentences
  end
end

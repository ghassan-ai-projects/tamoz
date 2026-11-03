# frozen_string_literal: true

# A profile whose `fast` role is a real provider, for EpisodeComposition's profile_builder in real-model runners.
module RealProfile
  module_function

  def builder(provider)
    lambda do |root:, model:, **|
      { 'profile' => { 'schema_version' => 1, 'profile_id' => 'tamoz-real', 'profile_version' => '1.0',
                       'canonical_root' => root },
        'roots' => { 'workspace' => root }, 'tools' => { 'allowed' => %w[read_file list_directory] },
        'policy' => { 'allow_changes' => false, 'default_check_safety' => 'read_only', 'graph_version' => '1',
                      'behavior_version' => '1.0', 'tool_catalog_digest' => "sha256:#{'0' * 64}" },
        'model_roles' => { 'fast' => { 'provider' => provider, 'model' => model,
                                       'normalized_settings' => { 'temperature' => '0',
                                                                  'response_format' => 'json_object' } } } }
    end
  end
end

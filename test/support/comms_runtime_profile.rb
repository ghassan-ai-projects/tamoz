# frozen_string_literal: true

# A channel surface pins the authority it runs under, so `comms serve`/`doctor`
# need the channel's profile to exist in the runtime directory before they can
# build a deployable descriptor (see WorkerRuntime#load_profile).
module CommsRuntimeProfile
  module_function

  def write(runtime_dir, workspace, profile_id: 'ops')
    tools = %w[list_directory read_file search_text apply_patch create_file]
    digest = catalog_digest(workspace, tools)
    document = {
      'profile' => { 'schema_version' => 1, 'profile_id' => profile_id,
                     'profile_version' => '1.0', 'canonical_root' => workspace },
      'roots' => { 'workspace' => workspace },
      'tools' => { 'allowed' => tools },
      'policy' => {
        'allow_changes' => true, 'default_check_safety' => 'read_only',
        'graph_version' => '1', 'behavior_version' => '1.0',
        'tool_catalog_digest' => digest,
        'unattended_catalog_digest' => digest
      }
    }
    directory = File.join(runtime_dir, 'profiles')
    FileUtils.mkdir_p(directory, mode: 0o700)
    path = File.join(directory, "#{profile_id}.yaml")
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
    path
  end

  def catalog_digest(workspace, tools)
    Tamoz::Agent::Toolbox.new(
      root: workspace, allow_changes: true, checks: {}, allowed_tools: tools
    ).catalog_digest
  end
end

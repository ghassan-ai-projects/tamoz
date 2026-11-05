# frozen_string_literal: true

require 'fileutils'
require 'psych'

module Tamoz
  module Evals
    module Benchmark
      # Writes the B0 comms fixture's runtime directory: config, approval policy, trusted profile, workspace files.
      module OpenclawCommsProvisioning
        ASK_POLICY = <<~YAML
          version: 1
          tool_tiers:
            apply_patch:
              tier: local_execute
              verb: execute
              grant_scopes: [once]
            run_check:
              tier: local_execute
              verb: execute
              grant_scopes: [once]
          fallback_tier:
            tier: read
            verb: unknown
            grant_scopes: [once]
          tiers:
            read:
              default: allow
            local_execute:
              default: ask
              grant_scopes: [once]
          grant_keys:
            local_execute: [verb, tool]
          rules: []
          evidence:
            approve: filesystem_operator
            deny: chat_bound
          simulations: []
          ask:
            timeout_s: %<timeout_s>s
            on_timeout: %<on_timeout>s
        YAML

        private

        def provision_runtime_directory(approval_ask)
          @workspace = File.join(@directory, 'workspace')
          runtime_dir = File.join(@directory, 'runtime')
          FileUtils.mkdir_p(@workspace)
          FileUtils.mkdir_p(runtime_dir, mode: 0o700)
          write_config(runtime_dir, approval_ask)
          write_profile(runtime_dir)
          runtime_dir
        end

        def seed_workspace_files
          File.write(File.join(@workspace, 'note.txt'), "hello\n")
          File.write(File.join(@workspace, 'other.txt'), "world\n")
        end

        def write_config(runtime_dir, approval_ask)
          document = {
            'runtime' => { 'schema_version' => 2 },
            'workspace' => { 'root' => @workspace },
            'sources' => {}
          }
          if approval_ask
            policy_dir = File.join(runtime_dir, 'policy')
            write_ask_policy(policy_dir, **approval_ask)
            document['approval'] = { 'profile' => 'unattended',
                                     'policy_path' => File.join(policy_dir, 'base.yaml') }
          end
          File.write(File.join(runtime_dir, 'config.yaml'), Psych.dump(document))
          File.chmod(0o600, File.join(runtime_dir, 'config.yaml'))
        end

        def write_ask_policy(policy_dir, timeout_s: 86_400, on_timeout: :park)
          FileUtils.mkdir_p(File.join(policy_dir, 'profiles'))
          File.write(File.join(policy_dir, 'base.yaml'), format(ASK_POLICY, timeout_s:, on_timeout:))
          File.write(File.join(policy_dir, 'profiles', 'unattended.yaml'), <<~YAML)
            profile:
              name: unattended
          YAML
        end

        def write_profile(runtime_dir)
          profile_id = OpenclawCommsFixture::PROFILE_ID
          directory = File.join(runtime_dir, 'profiles')
          FileUtils.mkdir_p(directory, mode: 0o700)
          path = File.join(directory, "#{profile_id}.yaml")
          File.write(path, Psych.dump(profile_document(profile_id)))
          File.chmod(0o600, path)
        end

        def profile_document(profile_id)
          tools = %w[list_directory read_file search_text apply_patch create_file]
          digest = Tamoz::Agent::Toolbox.new(
            root: @workspace, allow_changes: true, checks: {}, allowed_tools: tools
          ).catalog_digest
          {
            'profile' => { 'schema_version' => 1, 'profile_id' => profile_id,
                           'profile_version' => '1.0', 'canonical_root' => @workspace },
            'roots' => { 'workspace' => @workspace },
            'tools' => { 'allowed' => tools },
            'policy' => {
              'allow_changes' => true, 'default_check_safety' => 'read_only',
              'graph_version' => '1', 'behavior_version' => '1.0',
              'tool_catalog_digest' => digest, 'unattended_catalog_digest' => digest
            }
          }
        end
      end
    end
  end
end

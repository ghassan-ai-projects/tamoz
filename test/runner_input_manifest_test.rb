# frozen_string_literal: true

require_relative 'test_helper'

class RunnerInputManifestTest < Minitest::Test
  def test_directory_path_is_a_bounded_execution_error
    Dir.mktmpdir('tamoz-runner-manifest') do |directory|
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        Tamoz::Evals::Runner::InputManifest.from_path(directory)
      end

      assert_equal 'runner input manifest is required', error.message
    end
  end

  def test_invalid_document_is_a_usage_error
    Dir.mktmpdir('tamoz-runner-manifest') do |directory|
      invalid = File.join(directory, 'invalid.json')
      File.write(invalid, 'not-json')

      assert_equal 'runner input manifest is invalid', assert_raises(
        Tamoz::Evals::Runner::InputManifest::Invalid
      ) { Tamoz::Evals::Runner::InputManifest.from_path(invalid) }.message
    end
  end

  def test_incomplete_document_is_a_usage_error
    Dir.mktmpdir('tamoz-runner-manifest') do |directory|
      incomplete = File.join(directory, 'incomplete.json')
      File.write(incomplete, JSON.generate('manifest_version' => 'runner-input-v1'))

      assert_equal 'runner input manifest is incomplete', assert_raises(
        Tamoz::Evals::Runner::InputManifest::Invalid
      ) { Tamoz::Evals::Runner::InputManifest.from_path(incomplete) }.message
    end
  end

  def test_repository_relative_input_is_rejected_before_construction
    RunnerInputs.with_manifest do |manifest|
      document = JSON.parse(File.read(manifest))
      descriptor = document.fetch('corpus_definitions').fetch('agent_smoke')
      descriptor['path'] = 'test/support/runner_inputs.rb'
      rewritten = File.join(File.dirname(manifest), 'relative.json')
      File.write(rewritten, JSON.generate(document))

      error = assert_raises(Tamoz::Evals::Runner::InputManifest::Invalid) do
        Tamoz::Evals::Runner::InputManifest.from_path(rewritten)
      end
      assert_equal 'runner input paths must be explicit and external', error.message
    end
  end

  def test_openclaw_requires_a_caller_owned_factory
    RunnerInputs.with_manifest do |manifest|
      input = Tamoz::Evals::Runner::InputManifest.from_path(manifest)
      error = assert_raises(Tamoz::Evals::ExecutionError) { input.openclaw_fixture! }

      assert_equal 'openclaw benchmark requires an external fixture factory', error.message
    end
  end

  def test_direct_construction_validates_external_documents
    RunnerInputs.with_manifest do |manifest|
      document = JSON.parse(File.read(manifest))
      document.fetch('corpus_definitions').fetch('agent_smoke')['sha256'] = '0' * 64

      assert_raises(Tamoz::Evals::Runner::InputManifest::Invalid) do
        Tamoz::Evals::Runner::InputManifest.new(
          external_root: document.fetch('external_root'),
          corpus_definitions: document.fetch('corpus_definitions'),
          scripted_model: document.fetch('scripted_model'),
          mcp_server: document.fetch('mcp_server'),
          openclaw: document.fetch('openclaw'),
          scenarios: document.fetch('scenarios')
        )
      end
    end
  end

  def test_mcp_arguments_must_be_strings
    RunnerInputs.with_manifest do |manifest|
      document = JSON.parse(File.read(manifest))
      document.fetch('mcp_server')['args'] = [1]
      path = File.join(File.dirname(manifest), 'bad-args.json')
      File.write(path, JSON.generate(document))

      error = assert_raises(Tamoz::Evals::Runner::InputManifest::Invalid) do
        Tamoz::Evals::Runner::InputManifest.from_path(path)
      end
      assert_equal 'mcp_server is incomplete', error.message
    end
  end
end

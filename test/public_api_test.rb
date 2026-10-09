# frozen_string_literal: true

require_relative "test_helper"

class PublicAPITest < Minitest::Test
  PACKAGE_VERSIONS = [
    Tamoz::Core::VERSION,
    Tamoz::ContextEngine::VERSION,
    Tamoz::Harness::VERSION,
    Tamoz::Graph::VERSION,
    Tamoz::SQLite::VERSION,
    Tamoz::Scheduler::VERSION,
    Tamoz::Stream::VERSION,
    Tamoz::Tools::VERSION,
    Tamoz::Agent::Kernel::VERSION,
    Tamoz::Agent::Memory::VERSION,
    Tamoz::Agent::Healing::VERSION,
    Tamoz::Agent::Profile::VERSION,
    Tamoz::Agent::Capabilities::VERSION,
    Tamoz::Agent::SessionGem::VERSION,
    Tamoz::Agent::Improvement::VERSION,
    Tamoz::Agent::CLI::VERSION,
    Tamoz::Agent::VERSION,
    Tamoz::Approval::VERSION,
    Tamoz::Cancellation::VERSION,
    Tamoz::Concurrency::VERSION,
    Tamoz::Evals::VERSION,
    Tamoz::Mcp::VERSION,
    Tamoz::Mcp::Websearch::VERSION,
    Tamoz::Comms::VERSION,
    Tamoz::Telegram::VERSION,
    Tamoz::Talk::VERSION,
    Tamoz::Observability::VERSION,
    Tamoz::OTel::VERSION
  ].freeze

  def test_documented_inventory_matches_loaded_public_surface
    inventory = read_json(ROOT.join("docs", "public-api.json")).fetch("packages")

    # The expected surface is independent of the generated manifest.
    assert_equal read_json(ROOT.join('test/fixtures/public_api_expected.json')), inventory

    inventory.each do |package, entries|
      entries.each do |entry, options|
        assert_public_entry(entry)
        assert_entry_options(entry, options, package:)
      end
    end
  end

  def test_package_versions_are_valid_and_begin_in_prerelease
    assert_equal GEM_ROOTS.keys.sort,
                 read_json(ROOT.join("docs", "public-api.json")).fetch("packages").keys.sort,
                 "every packaged gem must have a documented public surface"

    assert_equal 1, PACKAGE_VERSIONS.uniq.length
    assert Gem::Version.new(PACKAGE_VERSIONS.first).prerelease?
  end

  def test_reference_application_manifest_identifies_the_bounded_repair_milestone
    manifest = read_json(ROOT.join("apps", "tamoz-agent", "app.json"))

    assert_equal "Tamoz Agent", manifest.fetch("name")
    assert_equal "Tamoz::App", manifest.fetch("namespace")
    assert_equal "tamoz-agent-cli", manifest.fetch("runtime_package")
    assert_equal "bounded-repair-cli", manifest.fetch("status")
    assert_equal "working-slice-3", manifest.fetch("activation_milestone")
  end

  private

  def assert_entry_options(entry, options, package:)
    assert options.is_a?(Hash), "#{package} #{entry} options must be a Hash"
    allowed = options.keys.map(&:to_s).sort
    assert(allowed.all? { |key| key == "deprecated" },
           "#{package} #{entry} options may only be empty or deprecated: true")
    assert_equal true, options["deprecated"] if allowed.include?("deprecated")
  end

  def assert_public_entry(entry)
    if entry.match?(/\.[a-z_][a-z0-9_]*[!?]?\z/)
      constant_name, _separator, method_name = entry.rpartition(".")
      constant = constant_name.split("::").reject(&:empty?).reduce(Object) do |scope, name|
        scope.const_get(name, false)
      end
      assert_respond_to constant, method_name
    else
      constant = entry.split("::").reject(&:empty?).reduce(Object) do |scope, name|
        scope.const_get(name, false)
      end
      refute_nil constant
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class PublicAPITest < Minitest::Test
  def test_documented_inventory_matches_loaded_public_surface
    inventory = read_json(ROOT.join("docs", "public-api.json")).fetch("packages")

    assert_equal(
      {
        "tamoz-agent" => ["Tamoz::Agent::VERSION"],
        "tamoz-core" => ["Tamoz::Core::VERSION"],
        "tamoz-evals" => [
          "Tamoz::Evals::Case.load",
          "Tamoz::Evals::Result.load",
          "Tamoz::Evals::VERSION",
          "Tamoz::Evals.verify"
        ],
        "tamoz-graph" => ["Tamoz::Graph::VERSION"],
        "tamoz-sqlite" => ["Tamoz::SQLite::VERSION"]
      },
      inventory
    )

    inventory.each_value do |entries|
      entries.each { |entry| assert_public_entry(entry) }
    end
  end

  def test_package_versions_are_valid_and_begin_in_prerelease
    versions = [
      Tamoz::Core::VERSION,
      Tamoz::Graph::VERSION,
      Tamoz::SQLite::VERSION,
      Tamoz::Agent::VERSION,
      Tamoz::Evals::VERSION
    ]

    assert_equal 1, versions.uniq.length
    assert Gem::Version.new(versions.first).prerelease?
  end

  def test_reference_application_manifest_is_explicitly_non_executable_in_m0
    manifest = read_json(ROOT.join("apps", "tamoz-agent", "app.json"))

    assert_equal "Tamoz Agent", manifest.fetch("name")
    assert_equal "Tamoz::App", manifest.fetch("namespace")
    assert_equal "tamoz-agent", manifest.fetch("runtime_package")
    assert_equal "skeleton", manifest.fetch("status")
    assert_equal "M5a", manifest.fetch("activation_milestone")
  end

  private

  def assert_public_entry(entry)
    if entry.match?(/\.[a-z_][a-z0-9_]*\z/)
      constant_name, method_name = entry.split(/\.(?=[a-z_][a-z0-9_]*\z)/)
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

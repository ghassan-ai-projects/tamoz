# frozen_string_literal: true

require_relative "test_helper"
require "rubygems/package"

class PackagingTest < Minitest::Test
  def test_every_gem_is_strict_valid_and_contains_only_release_files
    GEM_ROOTS.each do |name, root|
      Dir.chdir(root) do
        spec = Gem::Specification.load("#{name}.gemspec")
        assert spec.validate(true), name

        assert_equal "true", spec.metadata.fetch("rubygems_mfa_required"), name
        assert spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.3.0")), name
        assert spec.required_ruby_version.satisfied_by?(Gem::Version.new("4.0.0")), name
        refute spec.required_ruby_version.satisfied_by?(Gem::Version.new("3.2.9")), name
        refute spec.required_ruby_version.satisfied_by?(Gem::Version.new("5.0.0")), name

        Dir.mktmpdir("tamoz-package") do |directory|
          output = File.join(directory, "#{name}.gem")
          Gem::Package.build(spec, false, true, output)
          contents = Gem::Package.new(output).contents

          assert_includes contents, "LICENSE", name
          assert_includes contents, "README.md", name
          assert(contents.any? { |path| path.start_with?("lib/") }, name)
          refute(contents.any? { |path| path.match?(%r{\A(?:test|spec|tmp|vendor|\.git)/}) }, name)

          next unless name == "tamoz-evals"

          assert_equal 12, contents.grep(%r{\Asuites/m0/golden/.+\.case\.json\z}).length
          assert_includes contents, "baselines/m0/baseline.result.json"
          assert_includes contents, "baselines/m0/evidence/baseline-summary.json"
          assert_equal(
            ["schemas/case.schema.json", "schemas/result.schema.json"],
            contents.grep(%r{\Aschemas/}).sort
          )
        end
      end
    end
  end

  def test_packaged_evals_executable_runs_without_repository_load_paths
    root = GEM_ROOTS.fetch("tamoz-evals")

    Dir.mktmpdir("tamoz-installed-evals") do |directory|
      package = File.join(directory, "tamoz-evals.gem")
      install_root = File.join(directory, "install")
      spec = Gem::Specification.load(root.join("tamoz-evals.gemspec").to_s)
      Dir.chdir(root) { Gem::Package.build(spec, false, true, package) }
      clean_environment = ENV.each_key
                             .grep(/\A(?:BUNDLE|BUNDLER)/)
                             .to_h { |key| [key, nil] }
                             .merge(
                               "GEM_HOME" => install_root,
                               "GEM_PATH" => install_root,
                               "RUBYLIB" => nil,
                               "RUBYOPT" => nil
                             )
      _stdout, stderr, status = Open3.capture3(
        clean_environment,
        RbConfig.ruby,
        "-S",
        "gem",
        "install",
        "--no-document",
        "--install-dir",
        install_root,
        package
      )
      assert status.success?, stderr

      executable = File.join(install_root, "bin", "tamoz-eval")
      stdout, stderr, status = Open3.capture3(
        clean_environment,
        RbConfig.ruby,
        executable,
        "--version"
      )
      assert status.success?, stderr
      assert_equal "#{Tamoz::Evals::VERSION}\n", stdout
      assert_empty stderr

      installed_root = File.join(install_root, "gems", spec.full_name)
      golden = Dir[File.join(installed_root, "suites", "m0", "golden", "*.case.json")].first
      refute_nil golden
      stdout, stderr, status = Open3.capture3(
        clean_environment,
        RbConfig.ruby,
        executable,
        "verify",
        golden
      )
      assert status.success?, stderr
      assert_includes stdout, '"decision":"verified"'
      assert_empty stderr

      baseline = File.join(installed_root, "baselines", "m0", "baseline.result.json")
      stdout, stderr, status = Open3.capture3(
        clean_environment,
        RbConfig.ruby,
        executable,
        "verify",
        baseline
      )
      assert_equal Tamoz::Evals::CLI::INSUFFICIENT_EVIDENCE, status.exitstatus
      assert_includes stdout, '"decision":"insufficient_evidence"'
      assert_empty stderr
    end
  end
end

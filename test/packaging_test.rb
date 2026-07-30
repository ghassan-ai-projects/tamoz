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
          assert_equal 4, contents.grep(%r{\Asuites/m1/core/.+\.case\.json\z}).length
          assert_equal 6, contents.grep(%r{\Asuites/m2/graph/.+\.case\.json\z}).length
          assert_includes contents, "baselines/m0/baseline.result.json"
          assert_includes contents, "baselines/m0/evidence/baseline-summary.json"
          assert_equal(
            [
              "schemas/case.schema.json",
              "schemas/evidence.schema.json",
              "schemas/result.schema.json"
            ],
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

  def test_packaged_core_runs_all_m1_primitives_without_repository_load_paths
    root = GEM_ROOTS.fetch("tamoz-core")

    Dir.mktmpdir("tamoz-installed-core") do |directory|
      package = File.join(directory, "tamoz-core.gem")
      install_root = File.join(directory, "install")
      spec = Gem::Specification.load(root.join("tamoz-core.gemspec").to_s)
      Dir.chdir(root) { Gem::Package.build(spec, false, true, package) }
      clean_environment = ENV.each_key
                             .grep(/\A(?:BUNDLE|BUNDLER)/)
                             .to_h { |key| [key, nil] }
                             .merge(
                               "GEM_HOME" => install_root,
                               "GEM_PATH" => ([install_root] + Gem.path).uniq.join(File::PATH_SEPARATOR),
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
        "--ignore-dependencies",
        "--install-dir",
        install_root,
        package
      )
      assert status.success?, stderr

      script = <<~'RUBY'
        require "json"
        require "tamoz/core"
        state = Tamoz::StateCodec.new.normalize("steps" => [{"id" => "inspect"}])
        context = Tamoz::Context.new(
          run_id: "run.1",
          execution_id: "execution.1",
          request_id: "request.1"
        )
        results = Tamoz::Pool.for(:threads, size: 1).map(state.fetch("steps")) do |step|
          context.child(step.fetch("id")).check!
          step.fetch("id")
        end
        sink = Tamoz::StreamSink.new(capacity: 1, run_id: "run.1")
        sink.emit(:custom, [], {"status" => "ok"})
        sink.finish
        feature = $LOADED_FEATURES.find { |path| path.end_with?("/tamoz/core.rb") }
        puts JSON.generate(
          "feature" => feature,
          "result" => results.first.value,
          "stream" => sink.each.first.data.fetch("status"),
          "graph_loaded" => $LOADED_FEATURES.any? { |path| path.end_with?("/tamoz/graph.rb") }
        )
      RUBY
      stdout, stderr, status = Open3.capture3(
        clean_environment,
        RbConfig.ruby,
        "-e",
        script
      )
      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert Pathname.new(result.fetch("feature")).realpath.to_s.start_with?(
        "#{Pathname.new(install_root).realpath}#{File::SEPARATOR}"
      )
      assert_equal "inspect", result.fetch("result")
      assert_equal "ok", result.fetch("stream")
      assert_equal false, result.fetch("graph_loaded")
      assert_empty stderr
    end
  end

  def test_packaged_graph_runs_m2_without_repository_load_paths
    core_root = GEM_ROOTS.fetch("tamoz-core")
    graph_root = GEM_ROOTS.fetch("tamoz-graph")

    Dir.mktmpdir("tamoz-installed-graph") do |directory|
      install_root = File.join(directory, "install")
      core_package = File.join(directory, "tamoz-core.gem")
      graph_package = File.join(directory, "tamoz-graph.gem")
      core_spec = Gem::Specification.load(core_root.join("tamoz-core.gemspec").to_s)
      graph_spec = Gem::Specification.load(graph_root.join("tamoz-graph.gemspec").to_s)
      Dir.chdir(core_root) { Gem::Package.build(core_spec, false, true, core_package) }
      Dir.chdir(graph_root) { Gem::Package.build(graph_spec, false, true, graph_package) }
      clean_environment = ENV.each_key
                             .grep(/\A(?:BUNDLE|BUNDLER)/)
                             .to_h { |key| [key, nil] }
                             .merge(
                               "GEM_HOME" => install_root,
                               "GEM_PATH" => ([install_root] + Gem.path).uniq.join(File::PATH_SEPARATOR),
                               "RUBYLIB" => nil,
                               "RUBYOPT" => nil
                             )
      [core_package, graph_package].each do |package|
        _stdout, stderr, status = Open3.capture3(
          clean_environment,
          RbConfig.ruby,
          "-S",
          "gem",
          "install",
          "--no-document",
          "--ignore-dependencies",
          "--install-dir",
          install_root,
          package
        )
        assert status.success?, stderr
      end

      script = <<~'RUBY'
        require "json"
        require "tamoz/graph"
        app = Tamoz.graph(name: "installed", version: "1") do
          state :events, reduce: :append, default: []
          node(
            :step,
            implementation_name: "installed.step",
            version: "1"
          ) { |_state, _context| {events: ["ok"]} }
          edge Tamoz::START, :step
          edge :step, Tamoz::END
        end.compile
        result = app.invoke(
          {},
          thread: "thread.1",
          request_id: "request.1",
          execution_id: "execution.1",
          concurrency: :threads
        )
        feature = $LOADED_FEATURES.find { |path| path.end_with?("/tamoz/graph.rb") }
        puts JSON.generate(
          "feature" => feature,
          "state" => result.state.transform_keys(&:to_s),
          "status" => result.status.to_s
        )
      RUBY
      stdout, stderr, status = Open3.capture3(
        clean_environment,
        RbConfig.ruby,
        "-e",
        script
      )
      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert Pathname.new(result.fetch("feature")).realpath.to_s.start_with?(
        "#{Pathname.new(install_root).realpath}#{File::SEPARATOR}"
      )
      assert_equal({"events" => ["ok"]}, result.fetch("state"))
      assert_equal "completed", result.fetch("status")
      assert_empty stderr
    end
  end
end

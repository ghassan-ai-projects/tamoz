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

          if name == "tamoz-agent"
            assert_equal ["tamoz"], spec.executables
            assert_includes contents, "exe/tamoz"
          end

          if name == "tamoz-stream"
            # The runtime notification contract must ship; goldens, dev vectors,
            # and the proto source must not.
            assert_includes contents, "contracts/notification-contract-v1.json", name
            refute(contents.any? { |path| path.match?(%r{\Acontracts/.*(?:goldens|vectors)}) }, name)
            refute(contents.any? { |path| path.end_with?(".proto") }, name)
          end

          next unless name == "tamoz-evals"

          assert_equal 12, contents.grep(%r{\Asuites/m0/golden/.+\.case\.json\z}).length
          assert_equal 4, contents.grep(%r{\Asuites/m1/core/.+\.case\.json\z}).length
          assert_equal 6, contents.grep(%r{\Asuites/m2/graph/.+\.case\.json\z}).length
          assert_equal 21, contents.grep(%r{\Asuites/agent/smoke/.+\.case\.json\z}).length
          assert_equal 5, contents.grep(%r{\Asuites/agent/memory/.+\.case\.json\z}).length
          assert_equal 2, contents.grep(%r{\Asuites/agent/memory_repository/.+\.case\.json\z}).length
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

  # tamoz-evals's harness subtree references Tamoz::Agent::*, Tamoz::SQLite::*,
  # and Tamoz::Mcp::* directly, so its gemspec declares those as real
  # dependencies (alongside tamoz-core). None of the four are published, so
  # they're built and installed locally with `--ignore-dependencies` — the
  # same pattern as `with_isolated_install`/the scorecard test below — rather
  # than asking `gem install` to resolve them from a registry.
  def test_packaged_evals_executable_runs_without_repository_load_paths
    names = %w[tamoz-core tamoz-graph tamoz-sqlite tamoz-approval tamoz-scheduler tamoz-stream tamoz-tools
               tamoz-agent tamoz-mcp tamoz-evals tamoz-comms tamoz-telegram tamoz-observability]
    with_isolated_install(names, "evals") do |environment|
      install_root = environment.fetch("GEM_HOME")
      spec = Gem::Specification.load(GEM_ROOTS.fetch("tamoz-evals").join("tamoz-evals.gemspec").to_s)
      clean_environment = environment

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

  # P10 slice 4: the governed-MCP gem joins the packaged scorecard, because case
  # 16 (`agent.mcp-governed-call`) drives the real MCP test server through
  # tamoz-mcp and the session. P16: tamoz-tools joins the packaged scorecard
  # because the agent gem now depends on it for the Toolbox and Skills surface.
  # P13: tamoz-scheduler joins because tamoz-sqlite implements the durable
  # ScheduleStore over the scheduler gem's contract.
  def test_packaged_agent_scorecard_runs_with_only_installed_tamoz_gems
    names = %w[tamoz-core tamoz-graph tamoz-sqlite tamoz-approval tamoz-scheduler tamoz-stream tamoz-tools tamoz-agent tamoz-mcp tamoz-evals tamoz-comms tamoz-telegram tamoz-observability]

    Dir.mktmpdir("tamoz-installed-scorecard") do |directory|
      install_root = File.join(directory, "install")
      packages = names.map do |name|
        root = GEM_ROOTS.fetch(name)
        specification = Gem::Specification.load(root.join("#{name}.gemspec").to_s)
        package = File.join(directory, "#{name}.gem")
        Dir.chdir(root) { Gem::Package.build(specification, false, true, package) }
        package
      end
      clean_environment = ENV.each_key
                             .grep(/\A(?:BUNDLE|BUNDLER)/)
                             .to_h { |key| [key, nil] }
                             .merge(
                               "GEM_HOME" => install_root,
                               "GEM_PATH" => ([install_root] + Gem.path).uniq.join(File::PATH_SEPARATOR),
                               "RUBYLIB" => nil,
                               "RUBYOPT" => nil,
                               # Case `agent.mcp-governed-call` drives the real SDK
                               # test server; the script lives outside every gem
                               # directory, so the packaged scorecard is pointed at
                               # the workspace copy.
                               "TAMOZ_MCP_SERVER_SCRIPT" =>
                                 File.join(ROOT, "script", "mcp_test_server").to_s
                             )
      packages.each do |package|
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

      executable = File.join(install_root, "bin", "tamoz-eval")
      stdout, stderr, status = Open3.capture3(
        clean_environment,
        RbConfig.ruby,
        executable,
        "scorecard",
        "agent-smoke"
      )
      assert status.success?, stderr
      report = JSON.parse(stdout)
      assert_equal "pass", report.fetch("decision")
      assert_equal 21, report.dig("corpus", "case_count")
      assert_equal 0, report.dig("aggregate", "unsafe_or_bypassed_actions")
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

  # P16 T6: the packaged tamoz-tools installs in isolation with only tamoz-core
  # and NOTHING else (the agent gem is absent), then constructs AND executes a
  # toolbox: a real configured check through Open3, a digest-bound patch, a
  # create_file mutation, and a compiled skills catalog. The `$LOADED_FEATURES`
  # scan proves no tamoz-agent feature was pulled in at runtime.
  def test_packaged_tools_runs_clean_with_only_core_installed
    core_root = GEM_ROOTS.fetch("tamoz-core")
    tools_root = GEM_ROOTS.fetch("tamoz-tools")

    Dir.mktmpdir("tamoz-installed-tools") do |directory|
      install_root = File.join(directory, "install")
      core_package = File.join(directory, "tamoz-core.gem")
      tools_package = File.join(directory, "tamoz-tools.gem")
      core_spec = Gem::Specification.load(core_root.join("tamoz-core.gemspec").to_s)
      tools_spec = Gem::Specification.load(tools_root.join("tamoz-tools.gemspec").to_s)
      Dir.chdir(core_root) { Gem::Package.build(core_spec, false, true, core_package) }
      Dir.chdir(tools_root) { Gem::Package.build(tools_spec, false, true, tools_package) }
      clean_environment = ENV.each_key
                             .grep(/\A(?:BUNDLE|BUNDLER)/)
                             .to_h { |key| [key, nil] }
                             .merge(
                               "GEM_HOME" => install_root,
                               "GEM_PATH" => ([install_root] + Gem.path).uniq.join(File::PATH_SEPARATOR),
                               "RUBYLIB" => nil,
                               "RUBYOPT" => nil
                             )
      [core_package, tools_package].each do |package|
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
        # encoding: UTF-8
        require "json"
        require "tmpdir"
        require "fileutils"
        require "digest"
        require "tamoz/tools"
        Dir.mktmpdir("tamoz-tools-packaged") do |root|
          File.write(File.join(root, "a.txt"), "hello world\n", encoding: Encoding::UTF_8)
          source = File.join(root, "operator")
          FileUtils.mkdir_p(File.join(source, "fix", "references"))
          File.write(
            File.join(source, "fix", "SKILL.md"),
            "---\nname: fix\ndescription: A bounded procedure.\nallowed-tools: [read_file]\n---\n\nBody.\n",
            encoding: Encoding::UTF_8
          )
          File.write(
            File.join(source, "fix", "references", "guide.md"),
            "Reference material.\n",
            encoding: Encoding::UTF_8
          )
          snapshot = Tamoz::Tools::Skills::Compiler.new(
            sources: [
              Tamoz::Tools::Skills::SkillSource.new(id: "operator", root: source, trust: "operator")
            ]
          ).compile
          toolbox = Tamoz::Tools::Toolbox.new(
            root:, allow_changes: true,
            checks: {"verify" => ["sh", "-c", "test -f a.txt && echo ok"]},
            check_safeties: {"verify" => :read_only},
            skills: snapshot
          )
          receipt = toolbox.execute("run_check", {"name" => "verify"})
          patch = toolbox.execute(
            "apply_patch",
            {"path" => "a.txt", "expected_sha256" => Digest::SHA256.hexdigest("hello world\n"),
             "before" => "hello", "after" => "goodbye"}
          )
          created = toolbox.execute("create_file", {"path" => "new.txt", "content" => "x\n"})
          loaded = toolbox.execute("load_skill", {"skill" => "operator/fix"})
          resource = toolbox.execute("read_skill_resource", {"skill" => "operator/fix", "path" => "references/guide.md"})
          puts JSON.generate(
            "check_passed" => receipt.passed?,
            "receipt_class" => receipt.class.name,
            "patched" => File.read(File.join(root, "a.txt")),
            "created" => File.exist?(File.join(root, "new.txt")),
            "skill_epoch" => toolbox.skill_epoch,
            "loaded" => loaded.include?("UNTRUSTED SKILL CONTENT"),
            "resource" => resource.include?("Reference material."),
            "agent_defined" => defined?(Tamoz::Agent).inspect,
            "agent_features" => $LOADED_FEATURES.select { |path| path.include?("/tamoz/agent") }
          )
        end
      RUBY
      stdout, stderr, status = Open3.capture3(
        clean_environment,
        RbConfig.ruby,
        "-e",
        script
      )
      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal true, result.fetch("check_passed")
      assert_equal "Tamoz::Tools::CheckReceipt", result.fetch("receipt_class")
      assert_equal "goodbye world\n", result.fetch("patched")
      assert_equal true, result.fetch("created")
      assert result.fetch("skill_epoch").start_with?("skills:1:")
      assert_equal true, result.fetch("loaded")
      assert_equal true, result.fetch("resource")
      assert_equal "nil", result.fetch("agent_defined")
      assert_empty result.fetch("agent_features")
      assert_empty stderr
    end
  end

  # P15-H (c)/(d): `tamoz-scheduler` and `tamoz-stream` ship as release gems but
  # had no isolated install proof — the workspace Gemfile resolves all nine gems
  # via `path:`, which masks a gemspec dependency error, and every other test
  # loads them through that Gemfile. Each is installed into its own GEM_HOME
  # with ONLY its declared dependency (`tamoz-core`) and exercised by a named
  # example task in a clean subprocess.
  def test_packaged_scheduler_runs_with_only_core_installed
    with_isolated_install(%w[tamoz-core tamoz-scheduler], "scheduler") do |environment|
      script = <<~'RUBY'
        require "json"
        require "tamoz/scheduler"
        anchor = 1_785_000_000
        schedule = Tamoz::Scheduler::Schedule.new(
          id: "nightly", owner: "human:op", kind: :interval, expression: "3600",
          start_at: anchor, payload_ref: "sha256:#{"0" * 64}",
          thread_policy: "thread.default",
          capability_grant: {"scopes" => ["read"]},
          behavior_version: "tamoz.agent.session/1",
          approval_policy: {"mode" => "deterministic", "risk" => "read_only"},
          delivery_policy: {"mode" => "inbox"}, budgets: {"max_steps" => 10},
          created_by: "human:op", created_at: anchor
        )
        occurrence = Tamoz::Scheduler::Occurrence.new(
          schedule_id: schedule.id, schedule_revision: schedule.revision,
          nominal_fire_at_utc: anchor, created_at: anchor
        )
        puts JSON.generate(
          "digest" => schedule.definition_digest,
          "occurrence_id" => occurrence.occurrence_id,
          "request_id" => occurrence.request_id,
          "kinds" => Tamoz::Scheduler::KINDS.map(&:to_s),
          "sqlite_defined" => defined?(Tamoz::SQLite).inspect,
          "agent_defined" => defined?(Tamoz::Agent).inspect
        )
      RUBY
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, "-e", script)

      assert status.success?, stderr
      result = JSON.parse(stdout)

      assert result.fetch("digest").start_with?("sha256:")
      refute_empty result.fetch("occurrence_id")
      refute_empty result.fetch("request_id")
      assert_equal %w[at interval], result.fetch("kinds")
      # The scheduler gem is a VALUES gem: it must not drag the durable store
      # or the agent in behind it.
      assert_equal "nil", result.fetch("sqlite_defined")
      assert_equal "nil", result.fetch("agent_defined")
      assert_empty stderr
    end
  end

  def test_packaged_stream_runs_with_only_core_installed
    with_isolated_install(%w[tamoz-core tamoz-stream], "stream") do |environment|
      script = <<~'RUBY'
        require "json"
        require "tamoz/stream"
        snapshot = {
          "situation_id" => "sit-1", "situation_version" => 7,
          "tenant_id" => "acme", "situation_type" => "equipment",
          "entity" => {"type" => "compressor", "id" => "c-01"},
          "facts" => {"pressure" => 0.2}
        }
        verified = Tamoz::Stream::ReceivedSnapshot.verify(
          Tamoz::Core.jcs(snapshot),
          Tamoz::Core.digest(:snapshot, snapshot)
        )
        store = Tamoz::Stream::ArtifactStore.new
        store.retain(digest: "sha256:#{"1" * 64}", bytes: "tool-catalog")
        # The notification contract JSON is read from the installed gem at
        # runtime; a missing packaged file raises ConformanceError here.
        contract = Tamoz::Stream::NotificationContract
        puts JSON.generate(
          "entity_id" => verified.fetch("entity").fetch("id"),
          "situation_version" => verified.fetch("situation_version"),
          "artifact_bytes" => store.resolve("sha256:#{"1" * 64}").fetch("bytes"),
          "contract_supported" => contract.supported_type?("io.agenticstream.outcome.recorded.v1"),
          "contract_unknown_rejected" => contract.supported_type?("io.example.not.a.type.v1"),
          "sqlite_defined" => defined?(Tamoz::SQLite).inspect,
          "agent_defined" => defined?(Tamoz::Agent).inspect
        )
      RUBY
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, "-e", script)

      assert status.success?, stderr
      result = JSON.parse(stdout)

      assert_equal "c-01", result.fetch("entity_id")
      assert_equal 7, result.fetch("situation_version")
      assert_equal "tool-catalog", result.fetch("artifact_bytes")
      assert_equal true, result.fetch("contract_supported")
      assert_equal false, result.fetch("contract_unknown_rejected")
      assert_equal "nil", result.fetch("sqlite_defined")
      assert_equal "nil", result.fetch("agent_defined")
      assert_empty stderr
    end
  end

  def test_packaged_observability_runs_with_only_core_installed
    with_isolated_install(%w[tamoz-core tamoz-observability], "observability") do |environment|
      script = <<~'RUBY'
        require "json"
        require "tamoz/observability"
        entry = Tamoz::Observability::Catalog.fetch("tamoz.model.call")
        signal = Tamoz::Observability::Signal.build(
          kind: :event, name: entry.name, timing: :point,
          correlation: {thread_id: "thread.1", execution_id: "execution.1"},
          observed_at_ms: 1, attributes: {provider: "fake"}
        )
        puts JSON.generate(
          "schema_version" => Tamoz::Observability::SCHEMA_VERSION,
          "signal_names" => Tamoz::Observability::Catalog.names.length,
          "trace_id" => Tamoz::Observability::Correlation.trace_id(
            thread_id: "thread.1", execution_id: "execution.1"
          ),
          "signal_frozen" => signal.frozen?,
          "sqlite_defined" => defined?(Tamoz::SQLite).inspect,
          "agent_defined" => defined?(Tamoz::Agent).inspect
        )
      RUBY
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, "-e", script)

      assert status.success?, stderr
      result = JSON.parse(stdout)

      assert_equal 1, result.fetch("schema_version")
      assert_equal 68, result.fetch("signal_names")
      assert_equal 16, result.fetch("trace_id").length
      assert_equal true, result.fetch("signal_frozen")
      assert_equal "nil", result.fetch("sqlite_defined")
      assert_equal "nil", result.fetch("agent_defined")
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

  private

  # Build the named gems, install them into their OWN GEM_HOME with
  # `--ignore-dependencies` (so a missing gemspec dependency shows up as a load
  # failure rather than being satisfied by a sibling), and yield an environment
  # that can see nothing but that install root.
  def with_isolated_install(names, label)
    Dir.mktmpdir("tamoz-installed-#{label}") do |directory|
      install_root = File.join(directory, "install")
      names.each do |name|
        root = GEM_ROOTS.fetch(name)
        specification = Gem::Specification.load(root.join("#{name}.gemspec").to_s)
        package = File.join(directory, "#{name}.gem")
        Dir.chdir(root) { Gem::Package.build(specification, false, true, package) }
        _stdout, stderr, status = Open3.capture3(
          ENV.each_key.grep(/\A(?:BUNDLE|BUNDLER)/).to_h { |key| [key, nil] },
          RbConfig.ruby, "-S", "gem", "install", "--no-document",
          "--ignore-dependencies", "--install-dir", install_root, package
        )
        assert status.success?, "#{name}: #{stderr}"
      end

      yield(
        ENV.each_key
           .grep(/\A(?:BUNDLE|BUNDLER)/)
           .to_h { |key| [key, nil] }
           .merge(
             "GEM_HOME" => install_root,
             "GEM_PATH" => ([install_root] + Gem.path).uniq.join(File::PATH_SEPARATOR),
             "RUBYLIB" => nil,
             "RUBYOPT" => nil
           )
      )
    end
  end
end

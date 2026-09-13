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

          assert_release_shape(name, contents)
          assert_family_release_policy(name, spec, contents, root)
        end
      end
    end
  end

  # The base verifier is intentionally installable without the runner or any
  # product runtime package. Its package test is the proof of that closure.
  def test_packaged_evals_executable_runs_without_repository_load_paths
    names = %w[tamoz-core tamoz-evals]
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

      stdout, stderr, status = Open3.capture3(
        clean_environment,
        RbConfig.ruby,
        "-e",
        'require "tamoz/evals"; abort "runner loaded" if defined?(Tamoz::Evals::Runner)'
      )
      assert status.success?, stderr
      assert_empty stdout
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

  # The installed runner receives every scripted input from an external adapter
  # and every case from an external index. No repository load path or package
  # fixture is available to this subprocess.
  def test_packaged_agent_scorecard_runs_with_only_installed_tamoz_gems
    names = %w[tamoz-cancellation tamoz-concurrency tamoz-core tamoz-graph tamoz-sqlite tamoz-approval tamoz-scheduler tamoz-stream tamoz-tools tamoz-agent-kernel tamoz-agent-memory tamoz-agent-healing tamoz-agent-profile tamoz-agent-capabilities tamoz-agent-session tamoz-agent-improvement tamoz-agent-cli tamoz-agent tamoz-mcp tamoz-mcp-websearch tamoz-evals tamoz-evals-runner tamoz-comms tamoz-comms-gateway tamoz-observability]

    Dir.mktmpdir("tamoz-installed-scorecard") do |directory|
      install_root = File.join(directory, "install")
      packages = names.map do |name|
        root = GEM_ROOTS.fetch(name)
        specification = Gem::Specification.load(root.join("#{name}.gemspec").to_s)
        package = File.join(directory, "#{name}.gem")
        Dir.chdir(root) { Gem::Package.build(specification, false, true, package) }
        package
      end
      packages.concat(external_dependency_packages(names))
      fixture_script = File.join(directory, "mcp_test_server.rb")
      FileUtils.cp(ROOT.join("script", "mcp_test_server"), fixture_script)
      manifest = build_runner_manifest(directory, fixture_script)
      clean_environment = ENV.each_key
                             .grep(/\A(?:BUNDLE|BUNDLER)/)
                             .to_h { |key| [key, nil] }
                             .merge(
                               "GEM_HOME" => install_root,
                               "GEM_PATH" => install_root,
                               "RUBYLIB" => nil,
                               "RUBYOPT" => nil
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

      executable = File.join(install_root, "bin", "tamoz-eval-runner")
      stdout, stderr, status = Open3.capture3(
        clean_environment,
        RbConfig.ruby,
        executable,
        "scorecard", "agent-smoke", "--input-manifest", manifest
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
    names = %w[tamoz-cancellation tamoz-concurrency tamoz-core]

    with_isolated_install(names, "core") do |clean_environment|
      install_root = clean_environment.fetch("GEM_HOME")

      script = <<~'RUBY'
        require "json"
        require "tamoz/core"
        require "tamoz/concurrency"
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

  def test_packaged_websearch_runs_with_only_declared_tamoz_closure
    with_hermetic_websearch_install("websearch") do |environment|
      script = <<~'RUBY'
        require "json"
        require "rubygems"
        require "tamoz/mcp/websearch"
        puts JSON.generate(
          "version" => Tamoz::Mcp::Websearch::VERSION,
          "feature" => $LOADED_FEATURES.find { |path| path.end_with?("/tamoz/mcp/websearch.rb") },
          "agent_loaded" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/agent") },
          "evals_loaded" => $LOADED_FEATURES.any? { |path| path.include?("/tamoz/evals") },
          "dependencies" => Gem.loaded_specs.fetch("tamoz-mcp-websearch").dependencies.map(&:name).sort
        )
      RUBY
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, "-e", script)
      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "0.1.0.alpha.1", result.fetch("version")
      assert Pathname.new(result.fetch("feature")).realpath.to_s.start_with?(Pathname.new(environment.fetch("GEM_HOME")).realpath.to_s)
      assert_equal false, result.fetch("agent_loaded")
      assert_equal false, result.fetch("evals_loaded")
      assert_equal %w[tamoz-core tamoz-mcp], result.fetch("dependencies")
      assert_empty stderr
    end
  end

  def test_packaged_comms_gateway_runs_with_injected_transport_and_store
    with_isolated_install(%w[tamoz-core tamoz-comms tamoz-comms-gateway], "comms-gateway") do |environment|
      script = <<~'RUBY'
        require "json"
        require "tamoz/comms/gateway"

        Descriptor = Struct.new(:surface_id, :identity, :transport, :limits, keyword_init: true)
        class Store
          attr_reader :calls

          def initialize
            @calls = []
            @rows = []
          end

          def acquire_poller_lease(**kwargs)
            @calls << [:acquire, kwargs]
            :acquired
          end

          def poll_offset(**kwargs)
            @calls << [:offset, kwargs]
            nil
          end

          def persist_next_offset(**kwargs)
            @calls << [:persist, kwargs]
            :persisted
          end

          def release_poller_lease(**kwargs)
            @calls << [:release, kwargs]
            :released
          end

          def add_delivery(row)
            @rows << row
          end

          def reconcile_expired_deliveries(now:)
            @calls << [:reconcile, now]
            :reconciled
          end

          def outbox_rows(**kwargs)
            @calls << [:rows, kwargs]
            @rows
          end

          def claim_delivery(**kwargs)
            @calls << [:claim, kwargs]
            :claimed
          end

          def reserve_delivery_slot(**kwargs)
            @calls << [:reserve, kwargs]
            0.0
          end

          def bind_journal_effect(**kwargs)
            @calls << [:bind, kwargs]
            :bound
          end

          def mark_delivery_send_started(**kwargs)
            @calls << [:send_started, kwargs]
            :marked
          end

          def mark_delivery(**kwargs)
            @calls << [:mark, kwargs]
            @rows.clear
            :marked
          end
        end

        class Adapter
          def initialize(store)
            @store = store
          end

          def bind_comms_store(*)
            @store
          end
        end

        class Transport
          attr_reader :polls, :deliveries, :authentications

          def initialize
            @polls = []
            @deliveries = []
            @authentications = []
          end

          def authenticate(descriptor, _credential)
            @authentications << descriptor.surface_id
            {"id" => descriptor.identity.fetch(:expected_bot_id)}
          end

          def poll(**kwargs)
            @polls << kwargs
            {updates: [], next_offset: nil}
          end

          def deliver(delivery)
            @deliveries << delivery
            {"message_id" => 42, "date" => 1}
          end
        end

        store = Store.new
        transport = Transport.new
        descriptor = Descriptor.new(
          surface_id: "injected",
          identity: {expected_bot_id: 7},
          transport: {poll_timeout_s: 0},
          limits: {
            control_capacity: 1, per_chat_messages_per_s: 1.0,
            global_messages_per_s: 25.0
          }
        )
        gateway = Tamoz::Comms::Gateway.new(
          adapter: Adapter.new(store), checkpoints: Object.new, transport:, descriptor:,
          poller_owner: "installed"
        )
        raise "start failed" unless gateway.start == :started
        raise "serve failed" unless gateway.serve_once(drain: false) == :served
        gateway.stop

        delivery = Tamoz::Comms::Delivery.build(
          conversation_id: "telegram:chat:1", kind: "answer", text: "hello",
          render_version: 1, content_digest: "a" * 64
        ).wire.merge("journaled" => 1)
        store.add_delivery(delivery)
        drainer = Tamoz::Comms::DeliveryDrainer.new(
          store:, transport:, descriptor:, owner: "installed:drainer", sleeper: ->(_seconds) {}
        )
        raise "drain failed" unless drainer.drain_once(now: Time.utc(2026, 8, 26, 12, 0, 0)) == :drained

        puts JSON.generate(
          "gateway" => defined?(Tamoz::Comms::Gateway),
          "drainer" => defined?(Tamoz::Comms::DeliveryDrainer),
          "telegram" => $LOADED_FEATURES.any? { |path| path.include?("tamoz/telegram") },
          "authenticated" => transport.authentications.length == 1,
          "polls" => transport.polls.length,
          "deliveries" => transport.deliveries.length,
          "store_calls" => store.calls.map(&:first)
        )
      RUBY
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, "-e", script)
      assert status.success?, stderr
      assert_equal(
        {
          "gateway" => "constant",
          "drainer" => "constant",
          "telegram" => false,
          "authenticated" => true,
          "polls" => 1,
          "deliveries" => 1,
          "store_calls" => %w[acquire acquire offset persist release reconcile rows claim reserve bind send_started mark]
        },
        JSON.parse(stdout)
      )
      assert_empty stderr
    end
  end

  def test_packaged_mcp_parent_has_no_websearch_http_or_resolv_closure
    with_hermetic_websearch_install(
      "mcp-parent",
      tamoz_names: %w[tamoz-cancellation tamoz-core tamoz-mcp]
    ) do |environment|
      script = <<~'RUBY'
        require "json"
        require "tamoz/mcp"
        puts JSON.generate(
          "websearch_file" => $LOADED_FEATURES.find { |path| path.end_with?("/tamoz/mcp/websearch.rb") },
          "websearch_defined" => defined?(Tamoz::Mcp::Websearch),
          "net_http" => $LOADED_FEATURES.any? { |path| path.include?("net/http") },
          "resolv" => $LOADED_FEATURES.any? { |path| path.include?("resolv") }
        )
      RUBY
      stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, "-e", script)
      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_nil result.fetch("websearch_file")
      assert_nil result.fetch("websearch_defined")
      assert_equal false, result.fetch("net_http")
      assert_equal false, result.fetch("resolv")
      assert_empty stderr
    end
  end

  def test_packaged_websearch_operator_gate_and_fixture_provider_are_hermetic
    with_hermetic_websearch_install("websearch-operator") do |environment|
      script = <<~'RUBY'
        require "json"
        load ENV.fetch("TAMOZ_OPERATOR_SCRIPT")
        policy = {
          "allowlisted_hosts" => ["api.search.example"],
          "schemes" => ["https"],
          "deny_private_ranges" => true,
          "max_request_bytes" => 2048,
          "max_response_bytes" => 4096,
          "connect_timeout_s" => 10,
          "redirect_max_hops" => 3,
          "circuit" => {"threshold" => 3, "scope_type" => "egress", "budget_breach" => true},
          "credential_refs" => []
        }
        ENV["TAMOZ_WEBSEARCH_EGRESS"] = JSON.generate(policy)
        ENV.delete("TAMOZ_SEARCH_API_TOKEN")
        refused = WebsearchAdapter.search_response("answer", 1)
        raise "grant gate did not refuse" unless refused.error? && refused.content.first.fetch(:text).include?("operator grant")
        ENV["TAMOZ_WEBSEARCH_GRANT"] = "1"
        ENV["TAMOZ_WEBSEARCH_PROVIDER"] = JSON.generate("provider" => "fixture")
        served = WebsearchAdapter.search_response("answer", 1)
        raise "fixture provider was not served" if served.error?
        raise "fixture result was not returned" unless served.content.first.fetch(:text).include?("42")
        puts JSON.generate("fixture" => true, "network" => false, "credential" => ENV.key?("TAMOZ_SEARCH_API_TOKEN"))
      RUBY
      stdout, stderr, status = Open3.capture3(
        environment.merge("TAMOZ_OPERATOR_SCRIPT" => ROOT.join("script", "websearch_adapter").to_s),
        RbConfig.ruby,
        "-e",
        script
      )
      assert status.success?, stderr
      assert_equal({"fixture" => true, "network" => false, "credential" => false}, JSON.parse(stdout))
      assert_empty stderr
    end
  end

  # P16 T6: the packaged tamoz-tools installs in isolation with only tamoz-core
  # and NOTHING else (the agent gem is absent), then constructs AND executes a
  # toolbox: a real configured check through Open3, a digest-bound patch, a
  # create_file mutation, and a compiled skills catalog. The `$LOADED_FEATURES`
  # scan proves no tamoz-agent feature was pulled in at runtime.
  def test_packaged_tools_runs_clean_with_only_core_installed
    names = %w[tamoz-cancellation tamoz-core tamoz-tools]

    with_isolated_install(names, "tools") do |clean_environment|
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
    with_isolated_install(%w[tamoz-core tamoz-cancellation tamoz-stream], "stream") do |environment|
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
    with_isolated_install(%w[tamoz-cancellation tamoz-concurrency tamoz-core tamoz-observability], "observability") do |environment|
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
    names = %w[tamoz-cancellation tamoz-concurrency tamoz-core tamoz-graph]

    with_isolated_install(names, "graph") do |clean_environment|
      install_root = clean_environment.fetch("GEM_HOME")

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

  # Every gem ships the release minimum and nothing test-shaped.
  def assert_release_shape(name, contents)
    assert_includes contents, "LICENSE", name
    assert_includes contents, "README.md", name
    assert(contents.any? { |path| path.start_with?("lib/") }, name)
    refute(contents.any? { |path| path.match?(%r{\A(?:test|spec|tmp|vendor|\.git)/}) }, name)
  end

  # One case per gem-family rule, so each family's policy reads on its own.
  def assert_family_release_policy(name, spec, contents, root)
    case name
    when "tamoz-agent-cli", "tamoz-agent"
      assert_agent_executables_policy(name, spec, contents)
    when "tamoz-stream"
      assert_stream_contract_policy(name, contents)
    when "tamoz-mcp-websearch", "tamoz-mcp"
      assert_websearch_partition_policy(name, contents)
    when "tamoz-evals-runner"
      assert_no_packaged_fixtures(name, contents)
      assert_evals_runner_source_policy(name, root, contents)
    when "tamoz-comms-gateway"
      assert_comms_gateway_entry_points(name, contents)
      assert_no_packaged_fixtures(name, contents)
      assert_comms_gateway_source_policy(name, root, contents)
    when "tamoz-evals"
      assert_evals_suite_policy(name, contents)
    end
  end

  def assert_agent_executables_policy(name, spec, contents)
    if name == "tamoz-agent-cli"
      assert_equal ["tamoz"], spec.executables
      assert_includes contents, "exe/tamoz"
    else
      assert_empty spec.executables
    end
  end

  def assert_stream_contract_policy(name, contents)
    # The runtime notification contract must ship; goldens, dev vectors, and
    # the proto source must not.
    assert_includes contents, "contracts/notification-contract-v1.json", name
    refute(contents.any? { |path| path.match?(%r{\Acontracts/.*(?:goldens|vectors)}) }, name)
    refute(contents.any? { |path| path.end_with?(".proto") }, name)
  end

  def assert_websearch_partition_policy(name, contents)
    if name == "tamoz-mcp-websearch"
      %w[
        lib/tamoz/mcp/websearch.rb
        lib/tamoz/mcp/websearch/version.rb
        lib/tamoz/mcp/websearch/egress_policy.rb
        lib/tamoz/mcp/websearch/egress_client.rb
        lib/tamoz/mcp/websearch/egress_circuit.rb
      ].each { |path| assert_includes contents, path, name }
    else
      refute contents.any? { |path| path.start_with?("lib/tamoz/mcp/websearch") }, name
    end
  end

  def assert_no_packaged_fixtures(name, contents)
    forbidden_paths = contents.grep(%r{(?:^|/)(?:fixtures?|spec|test)/|openclaw_comms_fixture|mcp_test_server})
    assert_empty forbidden_paths, "#{name} packaged fixture paths: #{forbidden_paths.inspect}"
  end

  def assert_evals_runner_source_policy(name, root, contents)
    forbidden_source = %w[
      OpenclawCommsFixture
      TamozInputFileModel
      CASE_DEFINITIONS
      RESTART_FIXTURE_CONTENT
      mcp_test_server
    ].select do |term|
      contents.grep(%r{\Alib/}).any? { |path| root.join(path).binread.include?(term) }
    end
    assert_empty forbidden_source, "#{name} packaged fixture source: #{forbidden_source.inspect}"
  end

  def assert_comms_gateway_entry_points(name, contents)
    assert_includes contents, "lib/tamoz/comms/gateway.rb", name
    assert_includes contents, "lib/tamoz/comms/delivery_drainer.rb", name
  end

  def assert_comms_gateway_source_policy(name, root, contents)
    forbidden_source = contents.grep(%r{\Alib/}).select do |path|
      root.join(path).binread.match?(
        /(?:OpenclawCommsFixture|(?:^|\W)(?:fixture|fake(?:_transport)?|mock(?:_transport)?|stub(?:_transport)?|test server)(?:\W|$))/i
      )
    end
    assert_empty forbidden_source, "#{name} packaged fixture source: #{forbidden_source.inspect}"
  end

  def assert_evals_suite_policy(_name, contents)
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

  def build_runner_manifest(directory, fixture_script)
    external_root = File.join(directory, "external-inputs")
    cases_root = File.join(external_root, "cases")
    FileUtils.mkdir_p(cases_root)
    external_fixture_script = File.join(external_root, "mcp_test_server.rb")
    FileUtils.cp(fixture_script, external_fixture_script)
    cases = Dir[ROOT.join("gems", "tamoz-evals", "suites", "agent", "smoke", "*.case.json").to_s].sort.map do |source|
      target = File.join(cases_root, File.basename(source))
      FileUtils.cp(source, target)
      target
    end
    cases_document = File.join(external_root, "agent-smoke.json")
    File.write(cases_document, JSON.generate("cases" => cases))

    corpus_source = File.join(external_root, "agent_smoke_corpus.rb")
    FileUtils.cp(ROOT.join("test", "support", "agent_smoke_corpus.rb"), corpus_source)

    runner_inputs_source = File.join(external_root, "runner_inputs.rb")
    FileUtils.cp(ROOT.join("test", "support", "runner_inputs.rb"), runner_inputs_source)

    empty_document = File.join(external_root, "empty.json")
    File.write(empty_document, "{}")
    adapter_path = File.join(external_root, "scripted-input-adapter.rb")
    File.write(adapter_path, packaged_runner_adapter(external_fixture_script, corpus_source, runner_inputs_source))

    descriptor = lambda do |path|
      {"path" => path, "sha256" => Digest::SHA256.file(path).hexdigest}
    end
    empty = descriptor.call(empty_document)
    cases_descriptor = descriptor.call(cases_document)
    adapter = descriptor.call(adapter_path)
    server = descriptor.call(external_fixture_script)
    manifest = {
      "manifest_version" => Tamoz::Evals::Runner::InputManifest::VERSION,
      "external_root" => external_root,
      "corpus_definitions" => {
        "agent_smoke" => cases_descriptor,
        "agent_memory" => empty,
        "agent_memory_repository" => empty
      },
      "scripted_model" => {"adapter" => adapter, "responses" => empty},
      "mcp_server" => {"path" => server.fetch("path"), "sha256" => server.fetch("sha256"), "args" => []},
      "openclaw" => {
        "fixture_factory_loader" => empty,
        "protocol" => empty,
        "catalog" => empty,
        "mission" => empty
      },
      "scenarios" => {
        "scenario_definitions" => empty,
        "sqlite_graph" => empty,
        "limits" => empty,
        "registry" => empty
      }
    }
    path = File.join(external_root, "manifest.json")
    File.write(path, JSON.generate(manifest))
    path
  end

  # The external adapter the installed runner loads: the scripted-input
  # vocabulary lives in RunnerInputs, copied beside the corpus so the
  # subprocess requires it from the manifest root — never from the repository.
  def packaged_runner_adapter(fixture_script, corpus_source, runner_inputs_source)
    <<~RUBY
      # frozen_string_literal: true

      require "json"
      require #{corpus_source.inspect}
      require #{runner_inputs_source.inspect}

      Tamoz::Evals::Runner::InputAdapters.tap do |adapter|
        adapter.scripted_model_factory = RunnerInputs.method(:scripted_model)
        adapter.scorecard_factory = lambda do |input_manifest:|
          Tamoz::Evals::Harness::AgentSmokeScorecard.new(
            corpus: Tamoz::Evals::Harness::AgentSmokeCorpus.new(input_manifest: input_manifest)
          )
        end
        adapter.scripted_model_script_factory = RunnerInputs.method(:scripted_model_script)
        adapter.scheduler_graph_factory = RunnerInputs.method(:scheduler_graph)
        adapter.memory_records = #{RunnerInputs.memory_records.inspect}
        adapter.memory_repository_config = #{RunnerInputs.memory_repository_config.inspect}
        adapter.websearch_inputs = #{RunnerInputs.websearch_inputs.merge(server_script: fixture_script).inspect}
        adapter.mcp_server_inputs = #{RunnerInputs.mcp_server_inputs.merge(server_script: fixture_script).inspect}
        adapter.security_inputs = #{RunnerInputs.security_inputs.inspect}
        adapter.skill_body = #{RunnerInputs.skill_body.inspect}
        adapter.skill_impostor_body = #{RunnerInputs.skill_impostor_body.inspect}
        adapter.scripted_model_child_source = #{RunnerInputs.scripted_model_child_source.inspect}
        adapter.subprocess_lib_paths = Gem.loaded_specs.values.filter_map do |spec|
          path = File.join(spec.full_gem_path, "lib")
          path if File.directory?(path)
        end
      end
    RUBY
  end

  def with_hermetic_websearch_install(label, tamoz_names: %w[tamoz-cancellation tamoz-core tamoz-mcp tamoz-mcp-websearch])
    external_names = %w[
      mcp json_schemer bigdecimal hana regexp_parser simpleidn zeitwerk
      faraday faraday-net_http net-http
    ]

    Dir.mktmpdir("tamoz-hermetic-#{label}") do |directory|
      install_root = File.join(directory, "install")
      environment = ENV.each_key
                       .grep(/\A(?:BUNDLE|BUNDLER)/)
                       .to_h { |key| [key, nil] }
                       .merge(
                         "GEM_HOME" => install_root,
                         "GEM_PATH" => install_root,
                         "RUBYLIB" => nil,
                         "RUBYOPT" => nil
                       )
      packages = tamoz_names.map do |name|
        root = GEM_ROOTS.fetch(name)
        specification = Gem::Specification.load(root.join("#{name}.gemspec").to_s)
        package = File.join(directory, "#{name}.gem")
        Dir.chdir(root) { Gem::Package.build(specification, false, true, package) }
        package
      end
      packages.concat(external_names.map { |name| Gem::Specification.find_by_name(name).cache_file })
      packages.each do |package|
        _stdout, stderr, status = Open3.capture3(
          environment,
          RbConfig.ruby,
          "-S", "gem", "install", "--no-document", "--ignore-dependencies",
          "--install-dir", install_root, package
        )
        assert status.success?, stderr
      end

      yield environment.merge(
        "TAMOZ_WEBSEARCH_GEM_LIB" => File.join(install_root, "gems", "tamoz-mcp-websearch-0.1.0.alpha.1", "lib"),
        "TAMOZ_MCP_GEM_LIB" => File.join(install_root, "gems", "tamoz-mcp-0.1.0.alpha.1", "lib"),
        "TAMOZ_CORE_GEM_LIB" => File.join(install_root, "gems", "tamoz-core-0.1.0.alpha.1", "lib"),
        "TAMOZ_CANCELLATION_GEM_LIB" => File.join(install_root, "gems", "tamoz-cancellation-0.1.0.alpha.1", "lib")
      )
    end
  end

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
      external_dependency_packages(names).each do |package|
        _stdout, stderr, status = Open3.capture3(
          ENV.each_key.grep(/\A(?:BUNDLE|BUNDLER)/).to_h { |key| [key, nil] },
          RbConfig.ruby, "-S", "gem", "install", "--no-document",
          "--ignore-dependencies", "--install-dir", install_root, package
        )
        assert status.success?, "#{package}: #{stderr}"
      end

      yield(
        ENV.each_key
           .grep(/\A(?:BUNDLE|BUNDLER)/)
           .to_h { |key| [key, nil] }
           .merge(
             "GEM_HOME" => install_root,
             "GEM_PATH" => install_root,
             "RUBYLIB" => nil,
             "RUBYOPT" => nil
           )
      )
    end
  end

  def external_dependency_packages(names)
    pending = names.dup
    visited = []
    packages = []

    until pending.empty?
      name = pending.shift
      next if visited.include?(name)

      visited << name
      specification = if name.start_with?("tamoz-")
                        root = GEM_ROOTS.fetch(name)
                        Gem::Specification.load(root.join("#{name}.gemspec").to_s)
                      else
                        Gem::Specification.find_by_name(name)
                      end
      specification.runtime_dependencies.each do |dependency|
        dependency_name = dependency.name
        next if dependency_name.start_with?("tamoz-")

        resolved = Gem::Specification.find_all_by_name(dependency_name).find do |candidate|
          dependency.requirement.satisfied_by?(candidate.version)
        end
        raise Gem::LoadError, "no installed #{dependency.requirement} for #{dependency_name}" unless resolved

        packages << resolved.cache_file
        pending << dependency_name
      end
    end

    packages.uniq
  end
end

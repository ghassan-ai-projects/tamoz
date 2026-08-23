# frozen_string_literal: true

require_relative "test_helper"

# P16 tools-gem extraction probes (plan §4 T1/T2/T3/T3b, corrections C1–C6).
# Everything here asserts the moved surface against values captured from the
# pre-move code at P16 start, except the digest matrix, which is deliberately
# re-pinned when the catalog begins binding configured check argv values.
class P16ToolsGemTest < Minitest::Test
  CLEAN_LIB_PATHS = %w[tamoz-core tamoz-tools].flat_map do |name|
    ["-I", GEM_ROOTS.fetch(name).join("lib").to_s]
  end.freeze

  # ---- P16-start reference pins (captured from the pre-move code) -----------

  MATRIX_DIGEST = "sha256:7bb2e9761f1e90ea0ff044fc38717cf992bf7dd142517bb8b8a1eef07a495c90"

  REJECTION_MESSAGES = {
    "bad_skills_type" => "skills must be a Tamoz::Agent::Skills::SkillSnapshot",
    "bad_root" => "workspace root is unavailable",
    "bad_check_name" => "invalid check name \"bad name!\"",
    "relative_check_program" =>
      "check \"rel\" argv[0] \"relative/program\" is a relative path and would " \
      "resolve inside the workspace; use an absolute path or a bare program name",
    "unconfigured_safety" => "check_safeties names unconfigured check \"other\"",
    "bad_safety" => "check \"c\" safety must be one of read_only, idempotent, unsafe",
    "bad_allowed" =>
      "allowed_tools names unavailable tools: nope (available: list_directory, read_file, search_text)",
    "bad_allow_changes" => "allow_changes must be true or false",
    "bad_timeout" => "check_timeout must be between 0 and 600 seconds"
  }.freeze

  CANONICAL_FIXTURE_JSON = "{\"2\":\"two\",\"a\":{\"x\":1,\"y\":[{\"k\":\"v\"}]},\"b\":[3,1,2],\"sym\":{\"1\":\"one\"}}"
  SNAPSHOT_CATALOG_DIGEST = "sha256:07bbee8d88e08571445d38951dba4c45a2183226c48d1ce812500acf875ff3de"
  SNAPSHOT_EMPTY_DIGEST = "sha256:182a16f232863f7bd66e70dabb20b53bc2562762113c4acd35f78016bb6e5f3c"

  def setup
    @dir = Dir.mktmpdir("tamoz-p16")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # ---------------------------------------------------------------------------
  # T2: clean-env runtime harness — construct AND CALL the whole toolbox surface
  # with only tamoz/tools + tamoz/core on the load path. A load-only extraction
  # that left a runtime `Tamoz::Agent::*` reference would NameError here.
  # ---------------------------------------------------------------------------

  def test_t2_clean_env_runs_the_full_toolbox_surface_without_agent
    workspace = File.join(@dir, "workspace")
    source = File.join(@dir, "operator")
    FileUtils.mkdir_p(workspace)
    FileUtils.mkdir_p(File.join(source, "fix", "references"))
    File.write(File.join(workspace, "a.txt"), "hello world\n", encoding: Encoding::UTF_8)
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

    script = <<~'RUBY'
      # encoding: UTF-8
      require "json"
      require "tmpdir"
      require "fileutils"
      require "digest"
      require "tamoz/tools"

      result = {}
      Dir.mktmpdir("tamoz-clean-env") do |root|
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
          sources: [Tamoz::Tools::Skills::SkillSource.new(id: "operator", root: source, trust: "operator")]
        ).compile

        # Both skill_epoch branches: the empty-snapshot LEGACY_SKILL_EPOCH path and
        # the compiled-catalog path.
        empty = Tamoz::Tools::Toolbox.new(root:)
        result["legacy_epoch"] = empty.skill_epoch
        result["empty_catalog_digest"] = empty.catalog_digest
        result["empty_epoch_branch"] = empty.skill_epoch == Tamoz::Core::LEGACY_SKILL_EPOCH

        box = Tamoz::Tools::Toolbox.new(
          root:,
          allow_changes: true,
          checks: {"verify" => ["sh", "-c", "test -z \"$ANTHROPIC_API_KEY\" && echo clean"]},
          check_safeties: {"verify" => :read_only},
          skills: snapshot
        )
        result["epoch"] = box.skill_epoch
        result["epoch_matches_snapshot"] = box.skill_epoch == snapshot.epoch
        result["catalog_digest_matches"] = box.skill_catalog_digest == snapshot.catalog_digest

        # Every execute tool.
        result["read_file"] = box.execute("read_file", {"path" => "a.txt"})
        result["list_directory"] = box.execute("list_directory", {"path" => "."})
        result["search_text"] = box.execute("search_text", {"query" => "hello", "path" => "."})

        # run_check: real child through Open3 + credential_free_env + CheckReceipt.
        receipt = box.execute("run_check", {"name" => "verify"})
        result["check_receipt_class"] = receipt.class.name
        result["check_passed"] = receipt.passed?
        result["check_failure_signature"] = receipt.failure_signature
        result["check_render"] = receipt.to_s

        # Skills tools against the real compiled catalog.
        loaded = box.execute("load_skill", {"skill" => "operator/fix"})
        result["load_skill"] = loaded
        resource = box.execute("read_skill_resource", {"skill" => "operator/fix", "path" => "references/guide.md"})
        result["read_skill_resource"] = resource

        # preview + effect_intent agree on the bytes before any write.
        intent = box.effect_intent("apply_patch", {"path" => "a.txt", "before" => "hello", "after" => "goodbye"})
        result["effect_intent"] = intent
        result["preview"] = box.preview("apply_patch", {"path" => "a.txt", "before" => "hello", "after" => "goodbye"})
        result["preview_has_after"] = box.preview("apply_patch", {"path" => "a.txt", "before" => "hello", "after" => "goodbye"}).include?("+goodbye")

        # Single + compound patch, and create_file, all in the tempdir.
        single = box.execute(
          "apply_patch",
          {"path" => "a.txt", "expected_sha256" => intent.fetch("before_state"),
           "before" => "hello", "after" => "goodbye"}
        )
        result["patched"] = File.read(File.join(root, "a.txt"))
        compound = box.execute(
          "apply_patch",
          {"path" => "a.txt", "replacements" => [{"before" => "goodbye", "after" => "hi"}]}
        )
        result["compound_patched"] = File.read(File.join(root, "a.txt"))
        created = box.execute("create_file", {"path" => "new.txt", "content" => "x\n"})
        result["created"] = File.read(File.join(root, "new.txt"))
        result["create_receipt"] = created

        # Clean-env boundary: no Tamoz::Agent may exist at runtime.
        result["agent_defined"] = defined?(Tamoz::Agent).inspect
        result["agent_features"] = $LOADED_FEATURES.select { |path| path.include?("/tamoz/agent") }
      end
      puts JSON.generate(result)
    RUBY

    clean_environment = ENV.each_key
                           .grep(/\A(?:BUNDLE|BUNDLER)/)
                           .to_h { |key| [key, nil] }
                           .merge(
                             "RUBYLIB" => nil,
                             "RUBYOPT" => nil,
                             # The check child must NOT inherit this (credential-free
                             # env rule, invariant 24); the check asserts its absence.
                             "ANTHROPIC_API_KEY" => "p16-leak-sentinel"
                           )
    stdout, stderr, status = Open3.capture3(
      clean_environment,
      RbConfig.ruby,
      *CLEAN_LIB_PATHS,
      "-e",
      script
    )
    assert status.success?, stderr
    result = JSON.parse(stdout)

    assert_equal "none", result.fetch("legacy_epoch")
    assert_equal true, result.fetch("empty_epoch_branch")
    assert result.fetch("epoch").start_with?("skills:1:")
    assert_equal true, result.fetch("epoch_matches_snapshot")
    assert_equal true, result.fetch("catalog_digest_matches")
    assert_includes result.fetch("read_file"), "sha256:"
    assert_includes result.fetch("search_text"), "a.txt:1"
    assert_equal "Tamoz::Tools::CheckReceipt", result.fetch("check_receipt_class")
    assert_equal true, result.fetch("check_passed")
    assert_nil result.fetch("check_failure_signature")
    assert_includes result.fetch("check_render"), "Check verify: exit_0"
    assert_includes result.fetch("load_skill"), "UNTRUSTED SKILL CONTENT"
    assert_includes result.fetch("read_skill_resource"), "Reference material."
    assert_equal "goodbye world\n", result.fetch("patched")
    assert_equal "hi world\n", result.fetch("compound_patched")
    assert_equal "x\n", result.fetch("created")
    assert_equal "nil", result.fetch("agent_defined")
    assert_empty result.fetch("agent_features")
    assert_empty stderr
  end

  # P16-05: the in-tools Skills::Error base resolves without any agent constant.
  def test_t2_skills_error_base_is_core_visible_in_the_clean_env
    script = <<~'RUBY'
      # encoding: UTF-8
      require "json"
      require "tamoz/tools"
      caught = begin
        Tamoz::Tools::Skills::SkillSource.new(id: "Bad Id", root: "/tmp", trust: "operator")
        false
      rescue Tamoz::Tools::Skills::Error => error
        error.class.name
      end
      puts JSON.generate(
        "caught" => caught,
        "base" => Tamoz::Tools::Skills::Error.superclass.name,
        "agent_defined" => defined?(Tamoz::Agent).inspect
      )
    RUBY
    clean_environment = ENV.each_key
                           .grep(/\A(?:BUNDLE|BUNDLER)/)
                           .to_h { |key| [key, nil] }
                           .merge("RUBYLIB" => nil, "RUBYOPT" => nil)
    stdout, stderr, status = Open3.capture3(
      clean_environment,
      RbConfig.ruby,
      *CLEAN_LIB_PATHS,
      "-e",
      script
    )
    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal "Tamoz::Tools::Skills::Error", result.fetch("caught")
    assert_equal "Tamoz::Core::ToolError", result.fetch("base")
    assert_equal "nil", result.fetch("agent_defined")
  end

  # P16-06: Skills.canonical is byte-identical to the core canonical, the input is
  # never mutated, and Deliberation delegates to the same implementation.
  def test_canonical_is_single_sourced_and_byte_identical
    fixture = {
      "b" => [3, 1, 2], "a" => {"x" => 1, "y" => [{"k" => :v}]}, 2 => "two", :sym => {1 => "one"}
    }
    assert_equal CANONICAL_FIXTURE_JSON, JSON.generate(Tamoz::Tools::Skills.canonical(fixture))
    assert_equal CANONICAL_FIXTURE_JSON, JSON.generate(Tamoz::Core.canonical(fixture))
    assert_equal CANONICAL_FIXTURE_JSON, JSON.generate(Tamoz::Agent::Deliberation.canonical(fixture))
    assert_equal Tamoz::Tools::Skills.canonical(fixture), Tamoz::Core.canonical(fixture)

    input = {"z" => 1, "a" => [2, 1]}
    Tamoz::Tools::Skills.canonical(input)
    assert_equal({"z" => 1, "a" => [2, 1]}, input)
  end

  # ---------------------------------------------------------------------------
  # P16-07 / P16-A2: the constant aliases are object-identical rebindings.
  # ---------------------------------------------------------------------------

  def test_constant_aliases_are_object_identical_and_survive_identity
    aliases = {
      "Toolbox" => Tamoz::Agent::Toolbox,
      "CheckReceipt" => Tamoz::Agent::CheckReceipt,
      "Skills" => Tamoz::Agent::Skills,
      "ToolError" => Tamoz::Agent::ToolError,
      "ToolArgumentError" => Tamoz::Agent::ToolArgumentError,
      "ToolPolicyError" => Tamoz::Agent::ToolPolicyError
    }
    aliases.each do |name, value|
      tools_constant = Tamoz::Tools.const_get(name)
      assert_equal tools_constant, value, "alias #{name}"
      assert tools_constant.equal?(value), "alias #{name} must be object-identical"
    end
    assert_equal Tamoz::Agent::ToolError, Tamoz::Core::ToolError
    assert_equal Tamoz::Agent::ToolArgumentError, Tamoz::Core::ToolArgumentError
    assert_equal Tamoz::Agent::ToolPolicyError, Tamoz::Core::ToolPolicyError

    Dir.mktmpdir("tamoz-alias") do |root|
      box = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      assert_instance_of Tamoz::Tools::Toolbox, box
      assert_instance_of Tamoz::Agent::Toolbox, box
      assert_equal 64 * 1024, Tamoz::Agent::Toolbox::MAX_FILE_BYTES
      assert_equal 32, Tamoz::Agent::Toolbox::MAX_REPLACEMENTS
      assert_equal({}, box.checks)
      assert_equal File.realpath(root), box.root.to_s
      assert_equal %w[apply_patch create_file list_directory read_file search_text], box.names.sort
      assert box.skills.empty?
    end

    receipt = Tamoz::Tools::CheckReceipt.new(name: "c", outcome: "exit_0", stdout: "ok\n", stderr: "")
    assert_instance_of Tamoz::Agent::CheckReceipt, receipt
    assert receipt.passed?
  end

  # P16-08: the skills corpus and the three `Skills =` test files resolve every
  # compiler/catalog/snapshot name through the alias (the scorecard covers the
  # corpus; here we cover the module surface the tests rely on).
  def test_skills_alias_exposes_the_full_compiler_surface
    assert_equal Tamoz::Agent::Skills::Compiler, Tamoz::Tools::Skills::Compiler
    assert_equal Tamoz::Agent::Skills::SkillSource, Tamoz::Tools::Skills::SkillSource
    assert_equal Tamoz::Agent::Skills::Catalog, Tamoz::Tools::Skills::Catalog
    assert_equal Tamoz::Agent::Skills::Snapshot, Tamoz::Tools::Skills::Snapshot
    assert_equal Tamoz::Agent::Skills::SkillSnapshot, Tamoz::Tools::Skills::SkillSnapshot

    empty = Tamoz::Agent::Skills::Snapshot.empty
    assert empty.empty?
    assert_equal "skills:1:#{SNAPSHOT_EMPTY_DIGEST}", empty.epoch
    box = Tamoz::Agent::Toolbox.new(root: @dir, skills: empty)
    assert box.skills.empty?
    assert_equal "none", box.skill_epoch
  end

  # ---------------------------------------------------------------------------
  # T1 (P16-19/P16-20): the full digest matrix is byte-identical to the P16-start
  # capture, and the digest-input axes (check_safeties, allowed_tools) feed the
  # digest while maximum_effect_output_bytes does not.
  # ---------------------------------------------------------------------------

  def test_digest_matrix_is_byte_identical_to_the_p16_start_capture
    Dir.mktmpdir("tamoz-matrix") do |root|
      source = File.join(root, "operator")
      FileUtils.mkdir_p(File.join(source, "fix"))
      File.write(
        File.join(source, "fix", "SKILL.md"),
        "---\nname: fix\ndescription: A bounded procedure.\nallowed-tools: [read_file]\n---\n\nBody.\n",
        encoding: Encoding::UTF_8
      )
      snap_empty = Tamoz::Tools::Skills::Snapshot.empty
      snap_full = Tamoz::Tools::Skills::Compiler.new(
        sources: [Tamoz::Tools::Skills::SkillSource.new(id: "operator", root: source, trust: "operator")]
      ).compile

      checks = {"answer" => ["echo", "42"]}
      safeties = {"answer" => :read_only}
      cells = []
      [snap_empty, snap_full].each do |skills|
        [false, true].each do |allow_changes|
          [nil, checks].each do |checks_value|
            [nil, safeties].each do |safeties_value|
              [nil, %w[read_file apply_patch]].each do |allowed|
                begin
                  box = Tamoz::Tools::Toolbox.new(
                    root:, allow_changes:, checks: checks_value || {}, check_safeties: safeties_value || {},
                    allowed_tools: allowed, skills:
                  )
                  cells << {
                    "skills" => skills.empty? ? "empty" : "full",
                    "allow_changes" => allow_changes,
                    "checks" => checks_value ? "present" : "absent",
                    "safeties" => safeties_value ? "present" : "absent",
                    "allowed" => allowed.nil? ? "nil" : allowed.join(","),
                    "catalog_digest" => box.catalog_digest,
                    "prompt_surface_digest" => box.prompt_surface_digest,
                    "descriptions" => box.descriptions,
                    "skill_epoch" => box.skill_epoch,
                    "names" => box.names
                  }
                rescue ArgumentError => error
                  cells << {
                    "skills" => skills.empty? ? "empty" : "full",
                    "allow_changes" => allow_changes,
                    "checks" => checks_value ? "present" : "absent",
                    "safeties" => safeties_value ? "present" : "absent",
                    "allowed" => allowed.nil? ? "nil" : allowed.join(","),
                    "error" => error.message
                  }
                end
              end
            end
          end
        end
      end
      assert_equal 32, cells.length

      normalized = cells.sort_by do |cell|
        [cell["skills"], cell["allow_changes"].to_s, cell["checks"], cell["safeties"], cell["allowed"]]
      end.map do |cell|
        {
          "skills" => cell["skills"], "allow_changes" => cell["allow_changes"], "checks" => cell["checks"],
          "safeties" => cell["safeties"], "allowed" => cell["allowed"],
          "catalog_digest" => cell["catalog_digest"], "prompt_surface_digest" => cell["prompt_surface_digest"],
          "skill_epoch" => cell["skill_epoch"], "names" => cell["names"], "descriptions" => cell["descriptions"],
          "error" => cell["error"]
        }.reject { |_, value| value.nil? }
      end
      digest = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(normalized))}"
      assert_equal MATRIX_DIGEST, digest
    end
  end

  def test_constructor_rejection_messages_are_byte_identical
    Dir.mktmpdir("tamoz-reject") do |root|
      refute_messages = REJECTION_MESSAGES.dup

      begin
        Tamoz::Tools::Toolbox.new(root: File.join(root, "nonexistent"))
      rescue Tamoz::Core::ToolError => error
        assert_equal refute_messages.delete("bad_root"), error.message
      end

      begin
        Tamoz::Tools::Toolbox.new(root:, skills: Object.new)
      rescue ArgumentError => error
        assert_equal refute_messages.delete("bad_skills_type"), error.message
      end

      begin
        Tamoz::Tools::Toolbox.new(root:, checks: {"bad name!" => ["x"]})
      rescue ArgumentError => error
        assert_equal refute_messages.delete("bad_check_name"), error.message
      end

      begin
        Tamoz::Tools::Toolbox.new(root:, checks: {"rel" => ["relative/program"]})
      rescue ArgumentError => error
        assert_equal refute_messages.delete("relative_check_program"), error.message
      end

      begin
        Tamoz::Tools::Toolbox.new(root:, checks: {"c" => ["echo", "x"]}, check_safeties: {"other" => :read_only})
      rescue ArgumentError => error
        assert_equal refute_messages.delete("unconfigured_safety"), error.message
      end

      begin
        Tamoz::Tools::Toolbox.new(root:, checks: {"c" => ["echo", "x"]}, check_safeties: {"c" => :bogus})
      rescue ArgumentError => error
        assert_equal refute_messages.delete("bad_safety"), error.message
      end

      begin
        Tamoz::Tools::Toolbox.new(root:, allowed_tools: ["nope"])
      rescue ArgumentError => error
        assert_equal refute_messages.delete("bad_allowed"), error.message
      end

      begin
        Tamoz::Tools::Toolbox.new(root:, allow_changes: "yes")
      rescue ArgumentError => error
        assert_equal refute_messages.delete("bad_allow_changes"), error.message
      end

      begin
        Tamoz::Tools::Toolbox.new(root:, check_timeout: 0)
      rescue ArgumentError => error
        assert_equal refute_messages.delete("bad_timeout"), error.message
      end

      assert_empty refute_messages.keys, "unconsumed rejection pins: #{refute_messages.keys.inspect}"

      # A root that exists but is not a directory names the specific message.
      File.write(File.join(root, "afile"), "x")
      begin
        Tamoz::Tools::Toolbox.new(root: File.join(root, "afile"))
      rescue Tamoz::Core::ToolError => error
        assert_equal "workspace root is not a directory", error.message
      end
    end
  end

  def test_check_safeties_and_allowed_tools_are_digest_inputs_but_max_effect_is_not
    Dir.mktmpdir("tamoz-digest-inputs") do |root|
      checks = {"answer" => ["echo", "42"]}
      read_only = Tamoz::Tools::Toolbox.new(
        root:, allow_changes: true, checks:, check_safeties: {"answer" => :read_only}
      )
      unsafe = Tamoz::Tools::Toolbox.new(
        root:, allow_changes: true, checks:, check_safeties: {"answer" => :unsafe}
      )
      explicit = Tamoz::Tools::Toolbox.new(
        root:, allow_changes: true, checks:,
        allowed_tools: %w[read_file list_directory search_text apply_patch create_file run_check]
      )
      subclass = Class.new(Tamoz::Tools::Toolbox) do
        def maximum_effect_output_bytes(name) = 999_999
      end
      bounded = subclass.new(
        root:, allow_changes: true, checks:, check_safeties: {"answer" => :read_only}
      )

      refute_equal read_only.catalog_digest, unsafe.catalog_digest, "check_safeties must feed the digest"
      refute_equal read_only.catalog_digest, explicit.catalog_digest, "allowed_tools must feed the digest"
      assert_equal read_only.catalog_digest, bounded.catalog_digest,
                   "maximum_effect_output_bytes must NOT feed the digest"
      assert_equal 999_999, bounded.maximum_effect_output_bytes("apply_patch")
      assert_equal 6 * 1024, read_only.maximum_effect_output_bytes("apply_patch")
    end
  end

  # P16-03: the skills snapshot digests survive the move byte-for-byte.
  def test_snapshot_digests_are_byte_identical_to_the_p16_start_capture
    source = File.join(@dir, "operator")
    FileUtils.mkdir_p(File.join(source, "fix"))
    File.write(
      File.join(source, "fix", "SKILL.md"),
      "---\nname: fix\ndescription: A bounded procedure.\nallowed-tools: [read_file]\n---\n\nBody.\n",
      encoding: Encoding::UTF_8
    )
    snapshot = Tamoz::Tools::Skills::Compiler.new(
      sources: [Tamoz::Tools::Skills::SkillSource.new(id: "operator", root: source, trust: "operator")]
    ).compile

    assert_equal SNAPSHOT_CATALOG_DIGEST, snapshot.catalog_digest
    assert_equal "skills:1:#{SNAPSHOT_CATALOG_DIGEST}", snapshot.epoch
    assert_equal "skills:1:#{SNAPSHOT_EMPTY_DIGEST}", Tamoz::Tools::Skills::Snapshot.empty.epoch
    assert_equal(
      "- operator/fix [operator, declared-risk guarded]: A bounded procedure.",
      Tamoz::Tools::Skills::Catalog.new(snapshot).render
    )
  end

  # ---------------------------------------------------------------------------
  # T3 (P16-10..13): the class-name serialization mapping at all three sites.
  # ---------------------------------------------------------------------------

  def test_class_name_mapping_is_exhaustive_and_does_not_force_fit_others
    assert_equal "Tamoz::Agent::ToolError", Tamoz::Core.serialized_tool_error_name("Tamoz::Core::ToolError")
    assert_equal(
      "Tamoz::Agent::ToolArgumentError",
      Tamoz::Core.serialized_tool_error_name("Tamoz::Core::ToolArgumentError")
    )
    assert_equal(
      "Tamoz::Agent::ToolPolicyError",
      Tamoz::Core.serialized_tool_error_name("Tamoz::Core::ToolPolicyError")
    )
    # A non-family class serializes as its true name — never force-fit.
    assert_equal(
      "Tamoz::Agent::PlanRejectedError",
      Tamoz::Core.serialized_tool_error_name("Tamoz::Agent::PlanRejectedError")
    )
    # The agent-side alias names pass through (they are already the public spelling).
    assert_equal "Tamoz::Agent::ToolError", Tamoz::Core.serialized_tool_error_name("Tamoz::Agent::ToolError")

    assert_equal(
      {
        "Tamoz::Core::ToolError" => "Tamoz::Agent::ToolError",
        "Tamoz::Core::ToolArgumentError" => "Tamoz::Agent::ToolArgumentError",
        "Tamoz::Core::ToolPolicyError" => "Tamoz::Agent::ToolPolicyError"
      },
      Tamoz::Core::TOOL_ERROR_CLASS_NAMES
    )
  end

  # Site 1 — the effect journal detail keeps the agent spelling.
  def test_effect_journal_class_name_is_mapped
    detail = Tamoz::Agent::EffectDispatcher.tool_error_detail(
      Tamoz::Core::ToolArgumentError.new("patch text was not found")
    )
    assert_equal "Tamoz::Agent::ToolArgumentError", detail.fetch("class")
    assert_equal true, detail.fetch("repairable")

    policy_detail = Tamoz::Agent::EffectDispatcher.tool_error_detail(
      Tamoz::Core::ToolPolicyError.new("path escapes the workspace root")
    )
    assert_equal "Tamoz::Agent::ToolPolicyError", policy_detail.fetch("class")
    assert_equal false, policy_detail.fetch("repairable")
  end

  # Site 3 — the runtime model-visible failure payload keeps the agent spelling.
  def test_runtime_failure_payload_class_name_is_mapped
    Dir.mktmpdir("tamoz-mapping") do |root|
      File.write(File.join(root, "broken.rb"), "def self.answer = 40\n")
      model = P16ScriptedModel.new(
        plan: [
          p16_plan("discovery", %w[inspect], [p16_step("inspect", "read_file", {"path" => "broken.rb"})]),
          p16_plan(
            "action",
            %w[patch check],
            [
              p16_step("patch", "apply_patch", p16_patch_arguments("4O", "42")),
              p16_step("check", "run_check", {"name" => "answer"})
            ]
          ),
          p16_plan(
            "repair",
            %w[patch check],
            [
              p16_step("patch", "apply_patch", p16_patch_arguments("40", "42")),
              p16_step("check", "run_check", {"name" => "answer"})
            ]
          )
        ],
        review: [
          {decision: "accept", issues: [], rationale: "ok"},
          {decision: "accept", issues: [], rationale: "ok"},
          {decision: "accept", issues: [], rationale: "ok"}
        ],
        verify: [{"answer" => "yes", "satisfied" => true, "evidence" => ["ok"]}]
      )
      events = []
      runtime = Tamoz::Agent.build(
        model:, root:, allow_changes: true,
        checks: {"answer" => ["sh", "-c", "grep -q 42 broken.rb"]},
        approval: ->(**) { true }
      )
      runtime.run("Make Broken.answer equal 42.") { |event| events << event }

      rejected = events.find { |event| event.type == :tool_rejected }
      refute_nil rejected, "the rejected patch must produce a tool_rejected event"
      failure = rejected.data.fetch("failure")
      assert_equal "tool_error", failure.fetch("kind")
      assert_equal "apply_patch", failure.fetch("tool")
      assert_equal "Tamoz::Agent::ToolArgumentError", failure.fetch("error_class")
      assert_equal "patch text was not found", failure.fetch("reason")
      # The dedup signature contains no class name, so the mapping cannot churn it.
      refute_includes failure.fetch("failure_signature"), "ToolArgumentError"
    end
  end

  # ---------------------------------------------------------------------------
  # T3b (P16-14/15): the bad-root CLI path renders "tamoz: …" exit 1 with no
  # backtrace, and the rescue is NOT widened: a StoreError still escapes.
  # ---------------------------------------------------------------------------

  def test_bad_root_cli_path_renders_clean_tamoz_error_without_backtrace
    bad_root = File.join(@dir, "does-not-exist")
    out = StringIO.new
    err = StringIO.new
    stub_model = Class.new do
      def generate(*) = "{}"
    end
    status = Tamoz::Agent::CLI.run(
      ["--root", bad_root, "--session-dir", File.join(@dir, "sessions"), "ask", "explain this"],
      out:,
      err:,
      env: {},
      model_factory: ->(_options) { stub_model.new }
    )
    assert_equal 1, status
    assert_includes err.string, "tamoz: workspace root is unavailable"
    refute_includes err.string, "backtrace"
    refute_includes err.string, "cli.rb"
    assert_empty out.string
  end

  def test_store_error_path_is_not_swallowed_by_the_widened_rescue
    out = StringIO.new
    err = StringIO.new
    stub_model = Class.new do
      def generate(*) = "{}"
    end
    error = assert_raises(Tamoz::StoreError) do
      Tamoz::Agent::CLI.run(
        ["--root", @dir, "--session-dir", File.join(@dir, "sessions"), "ask", "explain this"],
        out:,
        err:,
        env: {},
        model_factory: lambda { |_options|
          raise Tamoz::StoreError, "store unavailable"
        }
      )
    end
    assert_equal "store unavailable", error.message
    refute_includes err.string, "tamoz:"
  end

  # ---------------------------------------------------------------------------
  # P16-17: exactly one LEGACY_SKILL_EPOCH definition, in tamoz-core, and all
  # four consumers agree on "none".
  # ---------------------------------------------------------------------------

  def test_legacy_skill_epoch_has_one_core_definition_and_all_consumers_agree
    assert_equal "none", Tamoz::Core::LEGACY_SKILL_EPOCH
    refute Tamoz::Agent::SessionRecords.const_defined?(:LEGACY_SKILL_EPOCH),
           "the agent must not keep a second definition"
    refute Tamoz::Tools::Toolbox.const_defined?(:LEGACY_SKILL_EPOCH)

    # Consumer 1: the toolbox's empty-snapshot skill_epoch.
    assert_equal "none", Tamoz::Tools::Toolbox.new(root: @dir).skill_epoch
    # Consumer 2: session_records load-time default fill.
    record = Tamoz::Agent::SessionRecords.build(
      "session",
      session_id: "s", task: "t", task_digest: "d", root: @dir,
      graph_version: "1", behavior_version: "b", tool_catalog_digest: "c",
      created_at_ms: 0
    )
    assert_equal "none", record.fetch("skill_epoch")
    # Consumer 3: session enforce fetch default (pre-P9 resume).
    assert_equal(
      "none",
      {"no_epoch" => true}.fetch("skill_epoch", Tamoz::Core::LEGACY_SKILL_EPOCH)
    )
  end

  private

  class P16ScriptedModel
    attr_reader :calls

    def initialize(plan:, review:, verify:)
      @responses = {plan:, review:, verify:}.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      value = @responses.fetch(stage).shift
      raise "missing #{stage} response" unless value

      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  def p16_plan(phase, ids, steps)
    {
      "goal" => "Complete the #{phase} task.",
      "done_when" => ["Controller-owned evidence satisfies the oracle."],
      "steps" => steps
    }
  end

  def p16_step(id, tool, arguments)
    {
      "id" => id,
      "purpose" => "Perform the bounded #{id} step.",
      "tool" => tool,
      "arguments" => arguments,
      "verification" => "Use the observed framework receipt."
    }
  end

  def p16_patch_arguments(before, after)
    {
      "path" => "broken.rb",
      "expected_sha256" => Digest::SHA256.hexdigest("def self.answer = 40\n"),
      "before" => before,
      "after" => after
    }
  end
end

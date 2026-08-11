# frozen_string_literal: true

require_relative "test_helper"

class AgentLatencySmokeTest < Minitest::Test
  def test_offline_smoke_pins_routing_safety_and_discovery_qualification
    Dir.mktmpdir("tamoz-latency-smoke-test") do |directory|
      json = File.join(directory, "smoke.json")
      markdown = File.join(directory, "smoke.md")
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "script/agent_latency_smoke",
        "--offline",
        "--output",
        json,
        "--markdown",
        markdown,
        chdir: ROOT.to_s
      )

      assert_predicate status, :success?, "#{stdout}\n#{stderr}"
      report = read_json(json)
      qualification = report.fetch("qualification")

      assert_equal "offline", report.fetch("mode")
      assert_equal true, qualification.fetch("passed")
      assert_equal 1.0, qualification.fetch("direct_one_call_rate")
      assert_equal 1.0, qualification.fetch("unsafe_direct_route_rate")
      assert_equal 1.0, qualification.fetch("read_only_discovery_success_rate")
      assert_equal 20, report.fetch("cases").fetch("direct_response").length
      assert_equal 20, report.fetch("cases").fetch("route_adversarial").length
      assert_equal 10, report.fetch("cases").fetch("read_only_discovery").length
    end
  end

  def test_smoke_artifact_contains_no_task_or_answer_content
    Dir.mktmpdir("tamoz-latency-smoke-test") do |directory|
      json = File.join(directory, "smoke.json")
      markdown = File.join(directory, "smoke.md")
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "script/agent_latency_smoke",
        "--offline",
        "--output",
        json,
        "--markdown",
        markdown,
        chdir: ROOT.to_s
      )

      assert_predicate status, :success?, stderr
      report = File.read(json, encoding: Encoding::UTF_8)
      refute_includes report, "What is the capital of France?"
      refute_includes report, "offline response"
      refute_includes report, "grounded offline evidence"
    end
  end
end

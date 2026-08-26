# frozen_string_literal: true

require "tmpdir"
require "tamoz/agent"
require "tamoz/sqlite"
require "tamoz/stream/episode_worker"
require "tamoz/stream/decision_node_builder"
require_relative "aquaculture_domain"

Stream = Tamoz::Stream

# P1 test composition: builds the SAME fixed production episode graph the
# worker launcher composes (Tamoz::Agent::EpisodeGraph + EpisodeNodes with the
# profile/frame/model-call/decision ports), wired to a fixture or proxy
# endpoint. Old runner-level tests that predate P1 used throwaway graphs; they
# now exercise the real fixed graph (gate 4: same graph, in-process driver).
module EpisodeComposition
  # The cross-repo prompt digest: the Go runtime computes
  # digest("situation-runtime/prompt/v1\n", {version, text}); the Ruby frame
  # verifies with the SAME rule, so tests must too.
  PROMPT_VERSION = "1.0"
  PROMPT_DOMAIN = "situation-runtime/prompt/v1\n"

  module_function

  def prompt_sha256(prompt, version = PROMPT_VERSION)
    Tamoz::Core.digest(PROMPT_DOMAIN, {"version" => version, "text" => prompt})
  end

  # The diagnosis catalog digest must be computed over the catalog the wire
  # actually carries (the climate domain is a separate catalog) — the digest
  # is over the parsed catalog document, so parse the passed JSON.
  def parse_catalog(catalog_json)
    Tamoz::Core.parse_json_strict(catalog_json)
  end

  def build(endpoint:, model: "local-model", tenant: "acme", artifact_store: nil, situation_recaller: nil, recall_caller: nil, tool_port: nil, gateway: nil, skills_source: nil, credential_ref: nil)
    # Short prefix: the directory is used for UDS socket paths, which cap at
    # ~104 bytes — "tamoz-episode-composition..." alone would exceed it.
    directory = Dir.mktmpdir("tamoz-ep")
    root = File.join(directory, "root")
    Dir.mkdir(root)
    profile_path = File.join(directory, "profile.yml")
    profile_document = AquacultureDomain.profile_document(endpoint:, root:, model:)
    profile_document.fetch("model_roles").fetch("fast")["credential_ref"] = credential_ref if credential_ref
    File.write(profile_path, Psych.dump(profile_document))
    File.chmod(0o600, profile_path)
    profile = Tamoz::Agent::Profile.preview_source(profile_path).document
    checkpointer = Tamoz::SQLite::Adapter.new(
      path: File.join(directory, "tamoz.db"),
      state_codec: Tamoz::Agent::Memory::Surface.codec
    )
    nodes = Tamoz::Agent::EpisodeNodes.new(
      profile:,
      frame_builder_factory: lambda do |catalog, objective|
        Tamoz::Agent::EpisodeFrameBuilder.new(catalog:, objective:)
      end,
      model_call_factory: lambda do |role|
        resolved_role = Tamoz::Agent::ModelCall.resolve_role(profile, role.fetch("name"))
        transport = Tamoz::Agent::ModelClientFactory.build(
          provider: resolved_role.provider,
          model: resolved_role.model,
          profile_role: resolved_role,
          environment: ENV,
          explicit_api_base: role.fetch("endpoint").to_s.empty? ? nil : role.fetch("endpoint"),
          gateway:
        )
        Tamoz::Agent::EpisodeModelCall.new(transport:)
      end,
      decision_builder: Stream::DecisionNodeBuilder.new,
      tool_call: Tamoz::Agent::EpisodeToolCall.new(tool_port: tool_port),
      skills_source: skills_source || {},
      situation_recaller: situation_recaller,
      recall_caller: recall_caller
    )
    app = Tamoz::Agent::EpisodeGraph.build(checkpointer:, nodes:)
    worker = Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      lane_config: Tamoz::Agent::LaneConfig.build("fast" => "flash", "deep" => "pro", "batch" => "flash")
    )
    # P2: a stub tool port is surfaced through the REAL capability-host seam
    # (the runner binds it as context.episode_tools), so the graph exercises
    # the same host path production uses.
    episode_tools = if tool_port
                      implementations = Stream::EpisodeCapabilityHost::PERMITTED.to_h do |name|
                        [name, lambda do |arguments, _context|
                          tool_port.execute(name, arguments || {})
                        end]
                      end
                      Stream::EpisodeCapabilityHost.new(implementations)
                    end
    runner = Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner,
      worker:,
      artifact_store: artifact_store,
      episode_tools: episode_tools
    )
    {app:, runner:, adapter: checkpointer, directory:}
  end

  # The P0B wire request the fixed graph consumes. All digests are computed by
  # the same rules the graph verifies, so a well-formed request reaches reason.
  def wire_request(
    episode_id: "ep-1", attempt: 1, fence: 1, kind: :EPISODE_KIND_DIAGNOSE,
    prompt: AquacultureDomain::PROMPT, snapshot: AquacultureDomain.snapshot,
    catalog_json: Tamoz::Core.jcs(AquacultureDomain::CATALOG),
    model_policy: "fast",
    intent_catalog_json: Tamoz::Core.jcs(AquacultureDomain::INTENT_CATALOG),
    intent_catalog_sha256: nil,
    diagnosis_catalog_sha256: nil,
    tool_catalog_json: nil, tool_catalog_sha256: nil,
    decision_schema_json: nil, decision_schema_sha256: nil,
    objective: AquacultureDomain::OBJECTIVE, objective_sha256: nil,
    snapshot_sha256: nil, evidence_tools_endpoint: nil, capability_token: nil,
    allowed_intent_types: %w[install_watch_condition start_aerator],
    skill_refs_json: nil,
    reconsideration: nil,
    risk_ceiling: :RISK_CLASS_R1
  )
    Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id:,
      attempt_id: "at-#{attempt}",
      fence:,
      tenant_id: snapshot.fetch("tenant_id"),
      situation_id: snapshot.fetch("situation_id"),
      situation_version: snapshot.fetch("situation_version"),
      snapshot_json: Tamoz::Core.jcs(snapshot),
      snapshot_sha256: snapshot_sha256 || Tamoz::Core.digest(:snapshot, snapshot),
      diagnosis_catalog_json: catalog_json,
      diagnosis_catalog_sha256: diagnosis_catalog_sha256 ||
                              Tamoz::Core.digest(:diagnosis_catalog, parse_catalog(catalog_json)),
      intent_catalog_json: intent_catalog_json,
      intent_catalog_sha256: intent_catalog_sha256 ||
                              Tamoz::Core.digest(:intent_catalog, parse_catalog(intent_catalog_json)),
      skill_refs_json: skill_refs_json,
      reconsideration: reconsideration,
      model_policy:,
      prompt:,
      prompt_version: PROMPT_VERSION,
      prompt_sha256: prompt_sha256(prompt),
      objective:,
      objective_sha256: objective_sha256 ||
                        Tamoz::Core.digest("situation-runtime/objective/v1\n", {"text" => objective}),
      tool_catalog_json: tool_catalog_json,
      tool_catalog_sha256: tool_catalog_sha256,
      decision_schema_json: decision_schema_json,
      decision_schema_sha256: decision_schema_sha256,
      evidence_tools_endpoint: evidence_tools_endpoint,
      capability_token: capability_token,
      kind:,
      lane: :EPISODE_LANE_FAST,
      risk_ceiling:,
      allowed_intent_types: allowed_intent_types,
      executor_name: "tamoz",
      dispatch_policy: :DISPATCH_POLICY_SHADOW
    )
  end

  # Runs one episode through the composed runner; returns [events, app].
  def run(composition, request)
    events = []
    composition.fetch(:runner).run(request).each { |event| events << event }
    [events, composition.fetch(:app)]
  end
end

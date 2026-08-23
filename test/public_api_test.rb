# frozen_string_literal: true

require_relative "test_helper"

# P16 (correction 9): the documented inventory is a pinned HASH of package ->
# { entry => options }. A `deprecated: true` option marks an entry that still
# resolves (constant aliases) but lives in another package now. `docs/public-api.json`
# is regenerated to match this exact shape.
class PublicAPITest < Minitest::Test
  def test_documented_inventory_matches_loaded_public_surface
    inventory = read_json(ROOT.join("docs", "public-api.json")).fetch("packages")

    assert_equal(
      {
        "tamoz-agent" => {
          "Tamoz::Agent.build" => {},
          "Tamoz::Agent::CLI.run" => {},
          "Tamoz::Agent::CheckReceipt" => {"deprecated" => true},
          "Tamoz::Agent::Deliberation" => {},
          "Tamoz::Agent::EffectDispatcher" => {},
          "Tamoz::Agent::Error" => {},
          "Tamoz::Agent::Event" => {},
          "Tamoz::Agent::McpCapabilitySource" => {},
          "Tamoz::Agent::McpCatalogSnapshotUnavailableError" => {},
          "Tamoz::Agent::Plan" => {},
          "Tamoz::Agent::PlanRejectedError" => {},
          "Tamoz::Agent::ProtocolError" => {},
          "Tamoz::Agent::Result" => {},
          "Tamoz::Agent::RubyLLMModel" => {},
          "Tamoz::Agent::Runtime" => {},
          "Tamoz::Agent::Session" => {},
          "Tamoz::Agent::SessionOutcome" => {},
          "Tamoz::Agent::SessionRecords" => {},
          "Tamoz::Agent::SessionView" => {},
          "Tamoz::Agent::SkillSnapshotUnavailableError" => {},
          "Tamoz::Agent::Skills" => {"deprecated" => true},
          "Tamoz::Agent::Step" => {},
          "Tamoz::Agent::ToolArgumentError" => {"deprecated" => true},
          "Tamoz::Agent::Toolbox" => {"deprecated" => true},
          "Tamoz::Agent::ToolError" => {"deprecated" => true},
          "Tamoz::Agent::ToolPolicyError" => {"deprecated" => true},
          "Tamoz::Agent::VERSION" => {}
        },
        "tamoz-approval" => {
          "Tamoz::Approval::Answer.parse" => {},
          "Tamoz::Approval::ConflictingResolutionError" => {},
          "Tamoz::Approval::Decision" => {},
          "Tamoz::Approval::DecisionLog" => {},
          "Tamoz::Approval.bundled_policy_path" => {},
          "Tamoz::Approval::Engine" => {},
          "Tamoz::Approval::Error" => {},
          "Tamoz::Approval::Grant" => {},
          "Tamoz::Approval::GrantOffer" => {},
          "Tamoz::Approval::GrantStore" => {},
          "Tamoz::Approval::InvalidPolicyError" => {},
          "Tamoz::Approval::InvalidScopeError" => {},
          "Tamoz::Approval::MemoryDecisionLog" => {},
          "Tamoz::Approval::MemoryGrantStore" => {},
          "Tamoz::Approval::PolicyDocument" => {},
          "Tamoz::Approval::Request" => {},
          "Tamoz::Approval::UnknownDecisionError" => {},
          "Tamoz::Approval::VERSION" => {}
        },
        "tamoz-comms" => {
          "Tamoz::Comms::AmbiguousDeliveryError" => {},
          "Tamoz::Comms::ApprovalPrompt" => {},
          "Tamoz::Comms::AuthenticationError" => {},
          "Tamoz::Comms::AuthorityEvidence.members" => {},
          "Tamoz::Comms::Binding" => {},
          "Tamoz::Comms::Canonical" => {},
          "Tamoz::Comms::Commands" => {},
          "Tamoz::Comms::CommsError" => {},
          "Tamoz::Comms::CommsStore" => {},
          "Tamoz::Comms::Conversation" => {},
          "Tamoz::Comms::DecisionRecord" => {},
          "Tamoz::Comms::DecisionStore" => {},
          "Tamoz::Comms::Delivery" => {},
          "Tamoz::Comms::DeliverySink" => {},
          "Tamoz::Comms::InboundEnvelope" => {},
          "Tamoz::Comms::InterruptDigest" => {},
          "Tamoz::Comms::PollerConflictError" => {},
          "Tamoz::Comms::Shapes" => {},
          "Tamoz::Comms::SurfaceDescriptor" => {},
          "Tamoz::Comms::ThrottledError" => {},
          "Tamoz::Comms::Transport" => {},
          "Tamoz::Comms::ValidationError" => {},
          "Tamoz::Comms::VERSION" => {}
        },
        "tamoz-core" => {
          "Tamoz.configuration" => {},
          "Tamoz.configure" => {},
          "Tamoz.configuration_finalized?" => {},
          "Tamoz.finalize_configuration!" => {},
          "Tamoz.instrument" => {},
          "Tamoz::CancellationToken" => {},
          "Tamoz::CancelledError" => {},
          "Tamoz::CheckpointConflictError" => {},
          "Tamoz::CheckpointCorruptionError" => {},
          "Tamoz::CheckpointError" => {},
          "Tamoz::CheckpointVersionError" => {},
          "Tamoz::Clock.monotonic" => {},
          "Tamoz::Configuration" => {},
          "Tamoz::ConfigurationError" => {},
          "Tamoz::Context" => {},
          "Tamoz::Core::LEGACY_SKILL_EPOCH" => {},
          "Tamoz::Core::TOOL_ERROR_CLASS_NAMES" => {},
          "Tamoz::Core::ToolArgumentError" => {},
          "Tamoz::Core::ToolError" => {},
          "Tamoz::Core::ToolPolicyError" => {},
          "Tamoz::Core::VERSION" => {},
          "Tamoz::Core.canonical" => {},
          "Tamoz::DisclosableMessage" => {},
          "Tamoz::EffectUnknownError" => {},
          "Tamoz::Emitter::Null" => {},
          "Tamoz::Error" => {},
          "Tamoz::GraphDefinitionError" => {},
          "Tamoz::InvalidUpdateError" => {},
          "Tamoz::LeaseLostError" => {},
          "Tamoz::NodeError" => {},
          "Tamoz::Notifier::Null" => {},
          "Tamoz::Pool.for" => {},
          "Tamoz::PoolCircuitOpenError" => {},
          "Tamoz::PoolWorkerError" => {},
          "Tamoz::RecursionLimitError" => {},
          "Tamoz::Secret" => {},
          "Tamoz::SensitiveValueError" => {},
          "Tamoz::StaleRequestError" => {},
          "Tamoz::StateCodec" => {},
          "Tamoz::StateCodec::Registration" => {},
          "Tamoz::StateLimitError" => {},
          "Tamoz::StoreError" => {},
          "Tamoz::StreamClosedError" => {},
          "Tamoz::StreamPart" => {},
          "Tamoz::StreamSink" => {},
          "Tamoz::TaskResult::Cancelled" => {},
          "Tamoz::TaskResult::Failed" => {},
          "Tamoz::TaskResult::Interrupted" => {},
          "Tamoz::TaskResult::Stuck" => {},
          "Tamoz::TaskResult::Succeeded" => {},
          "Tamoz::TimeoutError" => {},
          "Tamoz::UnsupportedValueError" => {}
        },
        "tamoz-evals" => {
          "Tamoz::Evals::Case.load" => {},
          "Tamoz::Evals::Evidence.load" => {},
          "Tamoz::Evals::Result.load" => {},
          "Tamoz::Evals::VERSION" => {},
          "Tamoz::Evals.verify" => {}
        },
        "tamoz-graph" => {
          "Tamoz.graph" => {},
          "Tamoz.interrupt" => {},
          "Tamoz.send_to" => {},
          "Tamoz::Command" => {},
          "Tamoz::END" => {},
          "Tamoz::Graph::Branch" => {},
          "Tamoz::Graph::Channel" => {},
          "Tamoz::Graph::Checkpoint" => {},
          "Tamoz::Graph::Compiled" => {},
          "Tamoz::Graph::Definition" => {},
          "Tamoz::Graph::Interrupt" => {},
          "Tamoz::Graph::Limits" => {},
          "Tamoz::Graph::MemoryCheckpointer" => {},
          "Tamoz::Graph::NodeSpec" => {},
          "Tamoz::Graph::RunResult" => {},
          "Tamoz::Graph::Snapshot" => {},
          "Tamoz::Graph::Task" => {},
          "Tamoz::Graph::VERSION" => {},
          "Tamoz::Managed::RemainingSteps" => {},
          "Tamoz::Reducers.append" => {},
          "Tamoz::Reducers.max" => {},
          "Tamoz::Reducers.merge" => {},
          "Tamoz::Reducers.min" => {},
          "Tamoz::Reducers.union" => {},
          "Tamoz::Reducers::Reducer" => {},
          "Tamoz::START" => {},
          "Tamoz::Send" => {}
        },
        "tamoz-mcp" => {
          "Tamoz::Mcp::AmbiguousOutcomeError" => {},
          "Tamoz::Mcp::Catalog" => {},
          "Tamoz::Mcp::Catalog.compile" => {},
          "Tamoz::Mcp::CatalogSnapshotUnavailableError" => {},
          "Tamoz::Mcp::Elicitation" => {},
          "Tamoz::Mcp::Elicitation.answer" => {},
          "Tamoz::Mcp::Elicitation.build" => {},
          "Tamoz::Mcp::Entry" => {},
          "Tamoz::Mcp::Error" => {},
          "Tamoz::Mcp::Invocation" => {},
          "Tamoz::Mcp::Invocation.call" => {},
          "Tamoz::Mcp::Invocation.descriptor_for" => {},
          "Tamoz::Mcp::Invocation.effect_key" => {},
          "Tamoz::Mcp::Invocation.reissue" => {},
          "Tamoz::Mcp::MemoryCircuitStore" => {},
          "Tamoz::Mcp::OutputLimitError" => {},
          "Tamoz::Mcp::ProtocolError" => {},
          "Tamoz::Mcp::ServerConfig" => {},
          "Tamoz::Mcp::ServerConfig::Budgets" => {},
          "Tamoz::Mcp::Supervisor" => {},
          "Tamoz::Mcp::ToolArgumentError" => {},
          "Tamoz::Mcp::ToolPolicyError" => {},
          "Tamoz::Mcp::UnavailableError" => {},
          "Tamoz::Mcp::VERSION" => {},
          "Tamoz::Mcp::ValidationError" => {}
        },
        "tamoz-observability" => {
          "Tamoz::Observability::Catalog" => {},
          "Tamoz::Observability::ContentPolicy" => {},
          "Tamoz::Observability::Correlation" => {},
          "Tamoz::Observability::DuplicateSignalError" => {},
          "Tamoz::Observability::ObservabilityError" => {},
          "Tamoz::Observability::Recorder" => {},
          "Tamoz::Observability::Recorder::Fanout" => {},
          "Tamoz::Observability::Recorder::Journal" => {},
          "Tamoz::Observability::Recorder::Memory" => {},
          "Tamoz::Observability::Recorder::Null" => {},
          "Tamoz::Observability::SCHEMA_VERSION" => {},
          "Tamoz::Observability::SchemaEvolutionError" => {},
          "Tamoz::Observability::Signal" => {},
          "Tamoz::Observability::SignalCatalog" => {},
          "Tamoz::Observability::Metrics" => {},
          "Tamoz::Observability::ModelCall" => {},
          "Tamoz::Observability::Notifier" => {},
          "Tamoz::Observability::Cost" => {},
          "Tamoz::Observability::PricingTable" => {},
          "Tamoz::Observability::Producer" => {},
          "Tamoz::Observability::TelemetryReader" => {},
          "Tamoz::Observability::Trace" => {},
          "Tamoz::Observability::Usage" => {},
          "Tamoz::Observability::UnregisteredSignalError" => {},
          "Tamoz::Observability::ValidationError" => {},
          "Tamoz::Observability::VERSION" => {}
        },
        "tamoz-otel" => {
          "Tamoz::OTel::AsyncExporter" => {},
          "Tamoz::OTel::EgressPolicy" => {},
          "Tamoz::OTel::HTTPExporter" => {},
          "Tamoz::OTel::VERSION" => {}
        },
        "tamoz-scheduler" => {
          "Tamoz::Scheduler::ClockRollbackError" => {},
          "Tamoz::Scheduler::GrantIntersector" => {},
          "Tamoz::Scheduler::KINDS" => {},
          "Tamoz::Scheduler::LeaseLostError" => {},
          "Tamoz::Scheduler::MISFIRE_POLICIES" => {},
          "Tamoz::Scheduler::MisfireLimitReachedError" => {},
          "Tamoz::Scheduler::OVERLAP_POLICIES" => {},
          "Tamoz::Scheduler::Occurrence" => {},
          "Tamoz::Scheduler::STATES" => {},
          "Tamoz::Scheduler::Schedule" => {},
          "Tamoz::Scheduler::ScheduleStore" => {},
          "Tamoz::Scheduler::SchedulerError" => {},
          "Tamoz::Scheduler::ScorecardSummaryConsumer" => {},
          "Tamoz::Scheduler::StoreConflictError" => {},
          "Tamoz::Scheduler::TERMINAL" => {},
          "Tamoz::Scheduler::VERSION" => {}
        },
        "tamoz-sqlite" => {
          "Tamoz::SQLite::VERSION" => {}
        },
        "tamoz-stream" => {
          "Tamoz::Stream::ApprovalRelay" => {},
          "Tamoz::Stream::ArtifactStore" => {},
          "Tamoz::Stream::BudgetExceededError" => {},
          "Tamoz::Stream::ContractMismatchError" => {},
          "Tamoz::Stream::DecisionBuilder" => {},
          "Tamoz::Stream::EpisodeCapabilityHost" => {},
          "Tamoz::Stream::EpisodeRequestEnvelope" => {},
          "Tamoz::Stream::EpisodeRequestInvalidError" => {},
          "Tamoz::Stream::EpisodeRunner" => {},
          "Tamoz::Stream::EpisodeStream" => {},
          "Tamoz::Stream::EpisodeStreamAdapter" => {},
          "Tamoz::Stream::EpisodeWorker" => {},
          "Tamoz::Stream::EvidenceClient" => {},
          "Tamoz::Stream::OutcomeSubscriber" => {},
          "Tamoz::Stream::Reconsideration" => {},
          "Tamoz::Stream::ReceivedSnapshot" => {},
          "Tamoz::Stream::SituationMemory" => {},
          "Tamoz::Stream::SnapshotDigestMismatchError" => {},
          "Tamoz::Stream::SnapshotIdentityError" => {},
          "Tamoz::Stream::StreamError" => {},
          "Tamoz::Stream::VERSION" => {},
          "Tamoz::Stream::VerificationStore" => {},
          "Tamoz::Stream::WorkerServer" => {}
        },
        "tamoz-telegram" => {
          "Tamoz::Telegram::Client" => {},
          "Tamoz::Telegram::Normalizer" => {},
          "Tamoz::Telegram::Transport" => {},
          "Tamoz::Telegram::VERSION" => {}
        },
        "tamoz-tools" => {
          "Tamoz::Tools::CheckReceipt" => {},
          "Tamoz::Tools::Skills" => {},
          "Tamoz::Tools::Skills::CATALOG_DIGEST_DOMAIN" => {},
          "Tamoz::Tools::Skills::Catalog" => {},
          "Tamoz::Tools::Skills::Compiler" => {},
          "Tamoz::Tools::Skills::Error" => {},
          "Tamoz::Tools::Skills::LIMITS" => {},
          "Tamoz::Tools::Skills::SNAPSHOT_FORMAT_VERSION" => {},
          "Tamoz::Tools::Skills::SkillCollision" => {},
          "Tamoz::Tools::Skills::SkillRejection" => {},
          "Tamoz::Tools::Skills::SkillRecord" => {},
          "Tamoz::Tools::Skills::SkillResource" => {},
          "Tamoz::Tools::Skills::SkillSnapshot" => {},
          "Tamoz::Tools::Skills::SkillSource" => {},
          "Tamoz::Tools::Skills::Snapshot" => {},
          "Tamoz::Tools::Skills.canonical" => {},
          "Tamoz::Tools::Skills.digest_of" => {},
          "Tamoz::Tools::Skills.read_resource" => {},
          "Tamoz::Tools::Skills.read_resource_entry!" => {},
          "Tamoz::Tools::Skills.render_load" => {},
          "Tamoz::Tools::Skills.render_resource" => {},
          "Tamoz::Tools::ToolArgumentError" => {},
          "Tamoz::Tools::ToolError" => {},
          "Tamoz::Tools::ToolPolicyError" => {},
          "Tamoz::Tools::Toolbox" => {},
          "Tamoz::Tools::VERSION" => {}
        }
      },
      inventory
    )

    inventory.each do |package, entries|
      entries.each do |entry, options|
        assert_public_entry(entry)
        assert options.is_a?(Hash), "#{package} #{entry} options must be a Hash"
        allowed = options.keys.map(&:to_s).sort
        assert(allowed.all? { |key| key == "deprecated" },
               "#{package} #{entry} options may only be empty or deprecated: true")
        assert_equal true, options["deprecated"] if allowed.include?("deprecated")
      end
    end
  end

  def test_package_versions_are_valid_and_begin_in_prerelease
    # P15-G: every SHIPPED gem's version is pinned here. tamoz-scheduler and
    # tamoz-stream ship in the release surface and were absent, so a version
    # skew in either could not have been caught by this gate.
    versions = [
      Tamoz::Core::VERSION,
      Tamoz::Graph::VERSION,
      Tamoz::SQLite::VERSION,
      Tamoz::Scheduler::VERSION,
      Tamoz::Stream::VERSION,
      Tamoz::Tools::VERSION,
      Tamoz::Agent::VERSION,
      Tamoz::Approval::VERSION,
      Tamoz::Evals::VERSION,
      Tamoz::Mcp::VERSION,
      Tamoz::Comms::VERSION,
      Tamoz::Telegram::VERSION,
      Tamoz::Observability::VERSION,
      Tamoz::OTel::VERSION
    ]

    assert_equal GEM_ROOTS.keys.sort,
                 read_json(ROOT.join("docs", "public-api.json")).fetch("packages").keys.sort,
                 "every packaged gem must have a documented public surface"

    assert_equal 1, versions.uniq.length
    assert Gem::Version.new(versions.first).prerelease?
  end

  def test_reference_application_manifest_identifies_the_bounded_repair_slice
    manifest = read_json(ROOT.join("apps", "tamoz-agent", "app.json"))

    assert_equal "Tamoz Agent", manifest.fetch("name")
    assert_equal "Tamoz::App", manifest.fetch("namespace")
    assert_equal "tamoz-agent", manifest.fetch("runtime_package")
    assert_equal "bounded-repair-cli", manifest.fetch("status")
    assert_equal "working-slice-3", manifest.fetch("activation_milestone")
  end

  private

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

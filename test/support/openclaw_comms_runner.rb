# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tempfile'

require 'tamoz/evals/benchmark/openclaw_comms_oracles'
require_relative 'openclaw_comms_cancellation_drives'
require_relative 'openclaw_comms_control_drives'
require_relative 'openclaw_comms_parity_drives'
require_relative 'openclaw_comms_recovery_drives'

module Tamoz
  module Evals
    module Benchmark
      # The Phase B0 comms scenario runner: drives each canonical scenario
      # through the composition harness (Normalizer → Gateway admit → SQLite
      # store → Worker drain → DeliveryDrainer receipts) as a FIXTURE run and
      # scores it with the deterministic controller-owned oracles. No
      # provider, no real transport, no claim: artifacts state the fake
      # transport explicitly. Scenarios whose seam is not landed at HEAD are
      # recorded as pending_seam, never faked.
      #
      # The offline half of B2 rides the same harness: scenarios whose fact
      # set both surfaces can express also drive the durable CLI queue path
      # (one durable thread reachable from both surfaces) and record typed
      # cross-surface parity — meaning-level comparisons plus honest
      # unavailable edges, never rendered-byte equality.
      class OpenclawCommsRunner
        SCHEMA_VERSION = 'openclaw.comms-scenario.v1'
        MANIFEST_SCHEMA_VERSION = 'openclaw.comms-manifest.v1'
        RUN_KIND = 'fixture'
        PROVIDER = 'fixture:deterministic-scripted'
        MODEL = 'scripted-provider'
        TRANSPORT = 'fake:scripted_transport_no_egress'
        MANIFEST_FILENAME = 'manifest.json'
        MAX_ARTIFACT_BYTES = 262_144

        # Seams whose scenario cannot be scored at HEAD land here as an
        # honest gap record; an empty map means every catalog scenario is
        # expressible over the seams this runner drives.
        PENDING_SEAM = {}.freeze

        # Surfaces each scenario's driver exercises. Scenarios without a CLI
        # leg stay telegram-only; their parity metric stays typed-unavailable.
        SURFACES_DRIVEN = {
          'C1' => %w[cli telegram],
          'C5' => %w[cli telegram],
          'C6' => %w[cli telegram],
          'C9' => %w[cli telegram]
        }.freeze

        Result = Data.define(:manifest, :artifacts)

        def self.run(**arguments)
          new(**arguments).run
        end

        ADAPTER_METHODS = %i[
          build model_factory crashing_factory crash_error
          surface_id surface_revision conversation_a conversation_b user_bound user_other user_unknown
          cancel_reason cli_cancel_payload cancel_reply
        ].freeze

        RunContext = Data.define(:artifact_base, :artifact_root, :git_revision, :command)

        def initialize(scenario_index_path:, external_adapter:, scenarios: nil, **run_context)
          context = RunContext.new(**run_context)
          @artifact_base = Pathname.new(context.artifact_base)
          @artifact_root = context.artifact_root
          @git_revision = context.git_revision
          @command = context.command
          @adapter = external_adapter
          validate_adapter!
          @index = JSON.parse(File.read(scenario_index_path, encoding: Encoding::UTF_8))
          @scenarios = scenarios || @index.fetch('scenarios')
                                          .select { |entry| entry['tier'] == 'C' }
                                          .map { |entry| entry.fetch('scenario_id') }
          validate_scenarios!
        end

        def run
          @failed = false
          directory = @artifact_base.join(@artifact_root)
          FileUtils.mkdir_p(directory)
          artifacts = @scenarios.map { |scenario_id| run_scenario(scenario_id, directory) }
          manifest = build_manifest(artifacts)
          write_atomic(directory.join(MANIFEST_FILENAME), "#{CanonicalJSON.dump(manifest)}\n")
          Result.new(manifest:, artifacts: artifacts.freeze)
        end

        def failed?
          @failed
        end

        DRIVERS = {
          'C1' => OpenclawCommsParityDrives, 'C6' => OpenclawCommsParityDrives,
          'C9' => OpenclawCommsParityDrives,
          'C2' => OpenclawCommsRecoveryDrives, 'C3' => OpenclawCommsRecoveryDrives,
          'C4' => OpenclawCommsRecoveryDrives,
          'C5' => OpenclawCommsControlDrives, 'C7' => OpenclawCommsControlDrives,
          'C8' => OpenclawCommsCancellationDrives
        }.freeze

        SINGLE_CONVERSATION_ORACLES = %w[C1 C2 C4 C5 C6 C7 C8].freeze

        REPORTED_ONLY_METRICS = %w[update_count latency_to_ack latency_to_terminal].freeze

        private

        def validate_scenarios!
          known = @index.fetch('scenarios').map { |entry| entry.fetch('scenario_id') }
          return if (@scenarios - known).empty? && !@scenarios.empty?

          raise SchemaError, "unknown comms scenarios:#{(@scenarios - known).join(',')}"
        end

        def validate_adapter!
          missing = ADAPTER_METHODS.reject { |method| @adapter.respond_to?(method) }
          return if missing.empty?

          raise SchemaError, "openclaw external adapter missing:#{missing.join(',')}"
        end

        def entry_for(scenario_id)
          @index.fetch('scenarios').find { |entry| entry.fetch('scenario_id') == scenario_id }
        end

        # -- one scenario record per branch.
        def run_scenario(scenario_id, directory)
          record = if PENDING_SEAM.key?(scenario_id)
                     pending_seam_record(scenario_id)
                   else
                     score(scenario_id)
                   end
          document = artifact_document(scenario_id, record)
          path = "#{scenario_id}.json"
          write_atomic(directory.join(path), "#{CanonicalJSON.dump(document)}\n")
          # pending_seam is an honest seam gap, not an oracle failure.
          @failed = true if %w[failed blocked].include?(record['status'])
          {
            'scenario_id' => scenario_id,
            'artifact_path' => path,
            'artifact_digest' => "sha256:#{Digest::SHA256.file(directory.join(path)).hexdigest}",
            'surfaces_driven' => surfaces_driven(scenario_id),
            'record' => record.slice('status', 'reason', 'metrics', 'hard_zero', 'parity')
          }
        end

        def surfaces_driven(scenario_id)
          SURFACES_DRIVEN.fetch(scenario_id, %w[telegram])
        end

        def pending_seam_record(scenario_id)
          {
            'status' => 'pending_seam',
            'reason' => PENDING_SEAM.fetch(scenario_id),
            'metrics' => {}, 'hard_zero' => {},
            'seam_revisions' => {}
          }
        end

        def score(scenario_id)
          facts = drive(scenario_id)
          scored = oracle_for(scenario_id, facts)
          fired = scored['hard_zero'].value?('failed')
          status = fired ? 'failed' : 'ready'
          status = 'failed' unless metrics_ready?(scored)
          scored.merge(
            'status' => status,
            'reason' => fired ? "hard_zero_fired:#{scored['hard_zero'].key('failed')}" : nil
          ).compact
        rescue StandardError => e
          { 'status' => 'blocked', 'reason' => "drive_error:#{e.class}:#{e.message}", 'metrics' => {},
            'hard_zero' => {}, 'seam_revisions' => {} }
        end

        def metrics_ready?(scored)
          scored['metrics'].except(*REPORTED_ONLY_METRICS)
                           .values
                           .reject { |value| value.is_a?(Hash) && value['status'] == 'unavailable' }
                           .all?(OpenclawCommsOracles::PASS)
        end

        def oracle_for(scenario_id, facts)
          case scenario_id
          when 'C3' then OpenclawCommsOracles.c3(facts)
          when 'C9'
            OpenclawCommsOracles.c9(facts, conversations: [@adapter.conversation_a, @adapter.conversation_b])
          when *SINGLE_CONVERSATION_ORACLES
            OpenclawCommsOracles.public_send(scenario_id.downcase, facts, conversation: @adapter.conversation_a)
          else raise SchemaError, "no oracle bound for #{scenario_id}"
          end
        end

        def artifact_document(scenario_id, record)
          entry = entry_for(scenario_id)
          {
            'schema_version' => SCHEMA_VERSION,
            'run_kind' => RUN_KIND,
            'fixture' => true,
            'transport' => TRANSPORT,
            'provider' => PROVIDER,
            'model' => MODEL,
            'scenario_id' => scenario_id,
            'oracle_id' => entry&.fetch('oracle_id'),
            'catalog_metrics' => entry&.fetch('metrics', []),
            'surfaces_driven' => surfaces_driven(scenario_id),
            'seed' => seed(scenario_id),
            'git_revision' => @git_revision,
            'command' => @command,
            'seam_revisions' => seam_revisions,
            'result' => record.except('seam_revisions')
          }
        end

        def seam_revisions
          {
            'comms_store_contract_version' => Tamoz::SQLite::CommsStore::CONTRACT_VERSION,
            'render_version' => Tamoz::Comms::Rendering::RENDER_VERSION,
            'lifecycle_request_ref_width' => Tamoz::Comms::Lifecycle::REQUEST_REF_WIDTH
          }
        end

        def seed(scenario_id)
          "paired_scenario_seed/#{Digest::SHA256.hexdigest("#{@artifact_root}/#{scenario_id}")[0, 12]}"
        end

        def build_manifest(artifacts)
          {
            'schema_version' => MANIFEST_SCHEMA_VERSION,
            'run_kind' => RUN_KIND,
            'fixture' => true,
            'transport' => TRANSPORT,
            'provider' => PROVIDER,
            'model' => MODEL,
            'artifact_root' => @artifact_root,
            'git_revision' => @git_revision,
            'command' => @command,
            'scenarios' => @scenarios,
            'surfaces_driven' => @scenarios.to_h { |scenario_id| [scenario_id, surfaces_driven(scenario_id)] },
            'pending_seam' => pending_seam_artifacts(artifacts),
            'results' => artifacts.to_h do |artifact|
              [artifact.fetch('scenario_id'), artifact.fetch('record').fetch('status')]
            end,
            'controls_passed' => false,
            'publication_blocked_reason' => 'fixture_or_fake_provider'
          }
        end

        def pending_seam_artifacts(artifacts)
          artifacts.select { |artifact| artifact.dig('record', 'status') == 'pending_seam' }
                   .to_h { |artifact| [artifact.fetch('scenario_id'), artifact] }
        end

        def write_atomic(path, bytes)
          raise SchemaError, 'comms artifact exceeds the size limit' if bytes.bytesize > MAX_ARTIFACT_BYTES

          Tamoz::Core::AtomicFile.replace(path, bytes, mode: 0o644, prefix: '.comms-')
        end

        # ---------------------------------------------------------- drives

        def drive(scenario_id)
          DRIVERS.fetch(scenario_id).new(@adapter).public_send("drive_#{scenario_id.downcase}")
        end
      end
    end
  end
end

Tamoz::Evals::Runner::InputAdapters.comms_runner_factory = lambda do
  Tamoz::Evals::Benchmark::OpenclawCommsRunner
end

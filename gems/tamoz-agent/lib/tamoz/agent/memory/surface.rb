# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # P11 §2 package boundary: `tamoz-agent` owns the memory surface
      # (canonical record, admission, retrieval, consolidation, promotion,
      # correction/deletion protocols) and depends on the structural
      # `Tamoz::SQLite::MemoryStore` contract. All P11 code lands under
      # `gems/tamoz-agent/lib/tamoz/agent/memory/`.
      module Surface
        module_function

        # Invariant 18: the MemoryRecord codec registered in the allowlist. An
        # unknown `format_version` fails before partial load
        # (CheckpointVersionError from StateCodec). The adapter that hosts the
        # memory Store must be constructed with this codec.
        def codec
          @codec ||= Tamoz::StateCodec.new.with_registration(
            tag: "tamoz.agent.memory_record",
            version: MemoryRecord::FORMAT_VERSION,
            klass: MemoryRecord,
            encoder: ->(record) { record.to_h },
            decoder: ->(hash) { MemoryRecord.from_h(hash) },
            immutability: ->(record) { record.frozen? }
          )
        end

        def memory_namespace(tenant)
          "tamoz.memory.#{SafeText.normalize(
            tenant, name: "memory tenant", max_bytes: 256,
            error_class: MemoryPolicyError
          )}"
        end

        # Secret-shaped content never enters admission, an index row's
        # searchable columns, a consolidation preimage, a prompt, or a receipt
        # (invariant 24). Delegates to Tamoz::Core.secret_shaped? — the one
        # pattern set, shared with the session-record credential gate and the
        # toolbox credential env pattern.
        def secret_shaped?(value)
          Tamoz::Core.secret_shaped?(value)
        end
      end

      # The per-tenant memory engine: one Store namespace (`tamoz.memory.<tenant>`),
      # one structural repository, the admission/retrieval/lifecycle policies,
      # and the bounded limits. It is provider-free on the admission/retrieval
      # path (invariant 11): the ONLY model call in the whole phase is the
      # bounded consolidation call (P11-C), on an explicitly provider-loaded
      # boundary.
      class Engine
        attr_reader :tenant, :adapter, :store, :repository, :limits, :clock

        def initialize(tenant:, adapter:, protection: nil, limits: MemoryLimits, clock: -> { Time.now })
          @tenant = SafeText.normalize(
            tenant, name: "memory tenant", max_bytes: 256,
            error_class: MemoryPolicyError
          )
          @adapter = adapter
          @store = adapter.store
          @protection = protection
          @limits = limits.freeze
          @clock = clock
          @repository = Tamoz::SQLite::MemoryStore.new(store: @store, clock: @clock)
          @admission = Admission.new(self)
          @retrieval = Retrieval.new(self)
          @lifecycle = Lifecycle.new(self)
          @consolidation = Consolidation.new(self)
          @transitions = TransitionRegistry.new(self)
          @wisdom = Wisdom.new(self)
          freeze
        end

        def namespace
          Surface.memory_namespace(@tenant)
        end

        def now_ms
          @clock.call.to_i * 1000
        end

        def admission = @admission
        def retrieval = @retrieval
        def lifecycle = @lifecycle
        def consolidation = @consolidation
        def transitions = @transitions
        def wisdom = @wisdom

        # The retrieval caller for this tenant/session.
        def caller(user:, project:, sensitivity: :internal, compatibility: {})
          {
            tenant: @tenant,
            user:,
            project:,
            sensitivity:,
            compatibility_graph: compatibility.fetch(:graph_version, "1"),
            compatibility_behavior: compatibility.fetch(:behavior_version, BEHAVIOR_VERSION)
          }
        end

        # The index metadata for a record (per-version snapshot).
        def index_for(record)
          scopes = record.scopes
          Tamoz::SQLite::MemoryStore::IndexRow.new(
            store_namespace: namespace,
            memory_id: record.memory_id,
            record_version: record.record_version,
            layer: record.layer.to_s,
            klass: record.klass.to_s,
            state: record.state.to_s,
            scopes_tenant: scopes.fetch("tenant", @tenant),
            scopes_user: scopes.fetch("user", ""),
            scopes_project: scopes.fetch("project", ""),
            scopes_situation_type: scopes["situation_type"],
            scopes_entity_type: scopes["entity_type"],
            scopes_entity_id: scopes["entity_id"],
            sensitivity: record.sensitivity.to_s,
            valid_until_ms: record.valid_until && (record.valid_until.to_i * 1000),
            compatibility_graph: record.compatibility.fetch("graph_version", "1"),
            compatibility_behavior: record.compatibility.fetch("behavior_version", BEHAVIOR_VERSION),
            statement_search: record.sensitive? ? nil : searchable_text(record),
            searchable: !record.sensitive?
          )
        end

        def searchable_text(record)
          text = record.statement.to_s.strip
          return nil if text.empty?

          # The bounded searchable projection: the first 512 bytes of the
          # statement, whitespace-collapsed. Exact/prefix matching only.
          collapsed = text.gsub(/\s+/, " ").strip[0, 512]
          collapsed
        end
      end
    end
  end
end

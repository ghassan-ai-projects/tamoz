# frozen_string_literal: true

require "tamoz/agent/errors"

module Tamoz
  module Agent
    # P0B/§4.3/§8.1: the immutable identities and receipt for one episode model
    # call. These freeze the SHAPE only; P2 binds them to the durable
    # EffectJournal (ModelReceipt is a typed VIEW of a journal receipt, not a new
    # store or table). Two identities are required (§8.1):
    #
    #   - LogicalCallKey is stable across worker attempts and fences: a
    #     redispatched attempt reuses a completed receipt or terminates unknown,
    #     so transport redispatch never becomes a fresh provider call.
    #   - InvocationIdentity records the attempt/fence/graph-task/stage/ordinal
    #     that produced a particular dispatch; these are callers of the logical
    #     key, not a fresh provider-call identity on redispatch.
    # rubocop:disable Metrics/ModuleLength -- one closed model-call identity and receipt surface.
    module ModelCall
      DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
      STATUSES = %i[succeeded failed unknown].freeze

      # episode + logical stage/slot + canonical request digest. `slot`
      # distinguishes several calls at the same stage (e.g. tool continuations).
      LogicalCallKey = Data.define(
        :episode_id, :stage, :slot, :request_digest, :provider_configuration_digest
      ) do
        def initialize(episode_id:, stage:, slot:, request_digest:, provider_configuration_digest: nil)
          ModelCall.require_present!("logical_call_key.episode_id", episode_id)
          ModelCall.require_present!("logical_call_key.stage", stage)
          ModelCall.require_digest!("logical_call_key.request_digest", request_digest)
          if provider_configuration_digest
            ModelCall.require_digest!(
              "logical_call_key.provider_configuration_digest", provider_configuration_digest
            )
          end
          super(episode_id:, stage:, slot: Integer(slot), request_digest:, provider_configuration_digest:)
        end

        # A stable string identity for journal dedup/lookup. Independent of
        # attempt/fence by construction.
        def to_key
          fields = [episode_id, stage, slot, request_digest]
          fields << provider_configuration_digest if provider_configuration_digest
          fields.join("\x00")
        end
      end

      InvocationIdentity = Data.define(:attempt_id, :fence, :graph_task, :stage, :global_ordinal) do
        def initialize(attempt_id:, fence:, graph_task:, stage:, global_ordinal:)
          ModelCall.require_present!("invocation.attempt_id", attempt_id)
          ModelCall.require_present!("invocation.stage", stage)
          super(
            attempt_id:, stage:, graph_task:,
            fence: Integer(fence), global_ordinal: Integer(global_ordinal)
          )
        end
      end

      # Normalized provider usage. `available:false` means the provider reported
      # no usage — the token/cost fields are nil, never a fabricated zero (§7.3).
      Usage = Data.define(:available, :input_tokens, :output_tokens, :cost_microunits) do
        def self.unavailable = new(available: false, input_tokens: nil, output_tokens: nil, cost_microunits: nil)

        def self.of(input_tokens:, output_tokens:, cost_microunits:)
          new(available: true, input_tokens: Integer(input_tokens),
              output_tokens: Integer(output_tokens), cost_microunits: Integer(cost_microunits))
        end

        def initialize(available:, input_tokens:, output_tokens:, cost_microunits:)
          if available && [input_tokens, output_tokens, cost_microunits].any?(&:nil?)
            raise ModelReceiptError, "usage/available_but_nil"
          end
          if !available && [input_tokens, output_tokens, cost_microunits].any? { |v| !v.nil? }
            raise ModelReceiptError, "usage/unavailable_but_present"
          end

          super
        end
      end

      # §4.3: a resolved operator model role. Profile is the only configuration
      # authority; the request names the role and the worker resolves it here
      # before a model call. revision/normalized_settings are optional until a
      # concrete model revision is pinned (§4.2 "minimally extend Profile").
      ModelRole = Data.define(
        :name, :provider, :model, :revision, :normalized_settings, :credential_ref, :profile_digest
      )

      # The immutable typed view of a completed/failed/unknown model call (§4.3).
      # `effect_key` is the journal storage key (logical-mode digest), so a
      # downstream verifier can fetch the durable record and cross-check the
      # receipt against it — node-authored projections are never trusted alone.
      ModelReceipt = Data.define(
        :logical_call_key, :invocation, :effect_id, :effect_key, :status,
        :provider, :model, :revision, :settings_digest, :provider_configuration_digest, :frame_digest,
        :request_digest, :response_digest, :artifact_refs,
        :usage, :provider_request_id, :retry_count, :started_at, :completed_at, :error_category
      ) do
        def initialize(logical_call_key:, invocation:, effect_id:, status:, provider:, model:,
                       request_digest:, usage:, retry_count:, started_at:,
                       revision: nil, settings_digest: nil, provider_configuration_digest: nil,
                       frame_digest: nil, response_digest: nil,
                       effect_key: nil, artifact_refs: [], provider_request_id: nil,
                       completed_at: nil, error_category: nil)
          validate_receipt!(
            logical_call_key:, invocation:, effect_id:, status:, provider:, model:,
            request_digest:, usage:, settings_digest:, response_digest:, provider_configuration_digest:
          )

          super(
            logical_call_key:, invocation:, effect_id:, effect_key:, status:, provider:, model:, revision:,
            settings_digest:, provider_configuration_digest:, frame_digest:, request_digest:, response_digest:,
            artifact_refs: artifact_refs.freeze,
            usage:, provider_request_id:, retry_count: Integer(retry_count), started_at:, completed_at:,
            error_category:
          )
        end

        def succeeded? = status == :succeeded
        def unknown? = status == :unknown

        private

        def validate_receipt!(logical_call_key:, invocation:, effect_id:, status:, provider:, model:,
                              request_digest:, usage:, settings_digest:, response_digest:,
                              provider_configuration_digest:)
          raise ModelReceiptError, "receipt/bad_status: #{status.inspect}" unless STATUSES.include?(status)
          raise ModelReceiptError, "receipt/logical_call_key_type" unless logical_call_key.is_a?(LogicalCallKey)
          raise ModelReceiptError, "receipt/invocation_type" unless invocation.is_a?(InvocationIdentity)
          raise ModelReceiptError, "receipt/usage_type" unless usage.is_a?(Usage)
          ModelCall.require_present!("receipt.effect_id", effect_id)
          ModelCall.require_present!("receipt.provider", provider)
          ModelCall.require_present!("receipt.model", model)
          ModelCall.require_digest!("receipt.request_digest", request_digest)
          if status == :succeeded
            ModelCall.require_digest!("receipt.settings_digest", settings_digest)
            ModelCall.require_digest!(
              "receipt.provider_configuration_digest", provider_configuration_digest
            )
          elsif settings_digest
            ModelCall.require_digest!("receipt.settings_digest", settings_digest)
          end
          # A succeeded call must carry the exact response digest it settled on; a
          # failed/unknown call may have none.
          return unless status == :succeeded || response_digest

          ModelCall.require_digest!("receipt.response_digest", response_digest)
        end
      end

      class << self
        # §4.3: resolve a model_policy to a concrete role via the Profile, the
        # sole operator configuration authority. Fails closed (before any model
        # call) when the role is absent/incomplete or the bound Profile digest
        # does not match the request's expectation.
        def resolve_role(profile, model_policy, expected_profile_digest: nil)
          require_present!("model_policy", model_policy)
          verify_profile_digest(profile, expected_profile_digest)
          role = find_model_role(profile, model_policy)
          provider, model = resolve_role_endpoint(role, model_policy)

          ModelRole.new(
            name: model_policy.to_s, provider: provider, model: model,
            revision: role_field(role, "revision"),
            normalized_settings: role_field(role, "normalized_settings") || {},
            credential_ref: role_field(role, "credential_ref"),
            profile_digest: profile.canonical_digest
          )
        end

        def require_present!(field, value)
          raise ModelReceiptError, "#{field}/blank" if value.nil? || (value.is_a?(String) && value.empty?)
        end

        def require_digest!(field, value)
          raise ModelReceiptError, "#{field}/bad_digest: #{value.inspect}" unless value.is_a?(String) && DIGEST_PATTERN.match?(value)
        end

        private

        def verify_profile_digest(profile, expected_profile_digest)
          return unless expected_profile_digest && profile.canonical_digest != expected_profile_digest

          raise ProfileRoleUnavailableError, "model_role/profile_digest_mismatch"
        end

        def find_model_role(profile, model_policy)
          role = profile.model_roles[model_policy.to_s] || profile.model_roles[model_policy.to_sym]
          raise ProfileRoleUnavailableError, "model_role/unknown: #{model_policy}" if role.nil?

          role
        end

        def resolve_role_endpoint(role, model_policy)
          provider = String(role_field(role, "provider") || "")
          model = String(role_field(role, "model") || "")
          if provider.empty? || model.empty?
            raise ProfileRoleUnavailableError, "model_role/incomplete: #{model_policy}"
          end

          [provider, model]
        end

        def role_field(role, name)
          role[name] || role[name.to_sym]
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end

CREATE TABLE tamoz_schema_migrations (
  version INTEGER PRIMARY KEY,
  checksum TEXT NOT NULL,
  applied_at_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_threads (
  thread_id TEXT PRIMARY KEY,
  tombstone_id TEXT,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_namespaces (
  thread_id TEXT NOT NULL,
  namespace TEXT NOT NULL,
  active_checkpoint_id TEXT,
  next_checkpoint_sequence INTEGER NOT NULL DEFAULT 0
    CHECK (next_checkpoint_sequence >= 0),
  next_request_sequence INTEGER NOT NULL DEFAULT 0
    CHECK (next_request_sequence >= 0),
  lease_owner_id TEXT,
  lease_fence INTEGER NOT NULL DEFAULT 0 CHECK (lease_fence >= 0),
  lease_expires_at_ms INTEGER,
  greatest_backend_time_ms INTEGER NOT NULL DEFAULT 0
    CHECK (greatest_backend_time_ms >= 0),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  PRIMARY KEY (thread_id, namespace),
  FOREIGN KEY (thread_id) REFERENCES tamoz_threads(thread_id)
    ON DELETE CASCADE
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_checkpoints (
  id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL,
  namespace TEXT NOT NULL,
  execution_id TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  parent_id TEXT,
  format_version INTEGER NOT NULL CHECK (format_version > 0),
  graph_name TEXT NOT NULL,
  graph_version TEXT NOT NULL,
  digest_version INTEGER NOT NULL CHECK (digest_version > 0),
  definition_digest TEXT NOT NULL,
  fence INTEGER NOT NULL CHECK (fence > 0),
  status TEXT NOT NULL CHECK (
    status IN ('running', 'paused', 'failed', 'completed')
  ),
  payload BLOB NOT NULL,
  payload_digest TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  UNIQUE (thread_id, namespace, sequence),
  FOREIGN KEY (thread_id, namespace)
    REFERENCES tamoz_namespaces(thread_id, namespace)
    ON DELETE CASCADE,
  FOREIGN KEY (parent_id) REFERENCES tamoz_checkpoints(id)
    ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
) STRICT

-- tamoz migration boundary --
CREATE INDEX idx_tamoz_checkpoint_history
  ON tamoz_checkpoints(thread_id, namespace, sequence DESC)

-- tamoz migration boundary --
CREATE INDEX idx_tamoz_checkpoint_execution
  ON tamoz_checkpoints(thread_id, namespace, execution_id, sequence DESC)

-- tamoz migration boundary --
CREATE TABLE tamoz_pending_activations (
  thread_id TEXT NOT NULL,
  namespace TEXT NOT NULL,
  execution_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  base_checkpoint_id TEXT NOT NULL,
  node TEXT NOT NULL,
  path BLOB NOT NULL,
  outcome_digest TEXT NOT NULL,
  consumed_by TEXT,
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY (thread_id, namespace, execution_id, task_id),
  FOREIGN KEY (thread_id, namespace)
    REFERENCES tamoz_namespaces(thread_id, namespace)
    ON DELETE CASCADE,
  FOREIGN KEY (base_checkpoint_id) REFERENCES tamoz_checkpoints(id)
    ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (consumed_by) REFERENCES tamoz_checkpoints(id)
    ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_pending_writes (
  thread_id TEXT NOT NULL,
  namespace TEXT NOT NULL,
  execution_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  write_index INTEGER NOT NULL CHECK (write_index >= 0),
  kind TEXT NOT NULL CHECK (kind IN ('channel', 'routes')),
  channel TEXT,
  payload BLOB NOT NULL,
  payload_digest TEXT NOT NULL,
  PRIMARY KEY (
    thread_id, namespace, execution_id, task_id, write_index
  ),
  FOREIGN KEY (thread_id, namespace, execution_id, task_id)
    REFERENCES tamoz_pending_activations(
      thread_id, namespace, execution_id, task_id
    )
    ON DELETE CASCADE
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_requests (
  thread_id TEXT NOT NULL,
  namespace TEXT NOT NULL,
  request_id TEXT NOT NULL,
  enqueue_sequence INTEGER NOT NULL CHECK (enqueue_sequence >= 0),
  input_digest TEXT NOT NULL,
  operation TEXT NOT NULL CHECK (
    operation IN ('turn', 'resume', 'retry', 'continue', 'fork', 'redirect', 'mode_switch')
  ),
  delivery_mode TEXT NOT NULL CHECK (
    delivery_mode IN ('queue', 'redirect')
  ),
  status TEXT NOT NULL CHECK (
    status IN (
      'queued', 'claimed', 'running', 'redirecting', 'completed', 'failed'
    )
  ),
  payload BLOB NOT NULL,
  payload_digest TEXT NOT NULL,
  execution_id TEXT,
  target_execution_id TEXT,
  cancellation_generation INTEGER,
  owner_fence INTEGER,
  checkpoint_id TEXT,
  response BLOB,
  response_digest TEXT,
  terminal_error BLOB,
  terminal_error_digest TEXT,
  retryable INTEGER CHECK (retryable IN (0, 1)),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  PRIMARY KEY (thread_id, namespace, request_id),
  UNIQUE (thread_id, namespace, enqueue_sequence),
  FOREIGN KEY (thread_id, namespace)
    REFERENCES tamoz_namespaces(thread_id, namespace)
    ON DELETE CASCADE,
  FOREIGN KEY (checkpoint_id) REFERENCES tamoz_checkpoints(id)
    ON DELETE NO ACTION DEFERRABLE INITIALLY DEFERRED
) STRICT

-- tamoz migration boundary --
CREATE INDEX idx_tamoz_request_queue
  ON tamoz_requests(thread_id, namespace, enqueue_sequence)
  WHERE status NOT IN ('completed', 'failed')

-- tamoz migration boundary --
CREATE TABLE tamoz_request_transitions (
  thread_id TEXT NOT NULL,
  namespace TEXT NOT NULL,
  request_id TEXT NOT NULL,
  transition_index INTEGER NOT NULL CHECK (transition_index >= 0),
  from_status TEXT,
  to_status TEXT NOT NULL,
  fence INTEGER,
  evidence BLOB,
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY (
    thread_id, namespace, request_id, transition_index
  ),
  FOREIGN KEY (thread_id, namespace, request_id)
    REFERENCES tamoz_requests(thread_id, namespace, request_id)
    ON DELETE CASCADE
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_effects (
  effect_key TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL,
  namespace TEXT NOT NULL,
  execution_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  call_index INTEGER NOT NULL CHECK (call_index >= 0),
  operation TEXT NOT NULL,
  safety TEXT NOT NULL CHECK (
    safety IN (
      'read_only', 'idempotent', 'transactional', 'reconcilable', 'unsafe'
    )
  ),
  request_digest TEXT NOT NULL,
  status TEXT NOT NULL CHECK (
    status IN (
      'prepared', 'running', 'succeeded', 'failed', 'unknown',
      'reconcile', 'abandoned'
    )
  ),
  current_attempt INTEGER CHECK (current_attempt > 0),
  requires_reconciliation INTEGER NOT NULL DEFAULT 0
    CHECK (requires_reconciliation IN (0, 1)),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL, logical_key TEXT, request_id TEXT,
  FOREIGN KEY (thread_id, namespace)
    REFERENCES tamoz_namespaces(thread_id, namespace)
    ON DELETE CASCADE
) STRICT

-- tamoz migration boundary --
CREATE INDEX idx_tamoz_effect_execution
  ON tamoz_effects(thread_id, namespace, execution_id)

-- tamoz migration boundary --
CREATE TABLE tamoz_effect_attempts (
  effect_key TEXT NOT NULL,
  attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
  attempt_token TEXT NOT NULL UNIQUE,
  fence INTEGER NOT NULL CHECK (fence > 0),
  status TEXT NOT NULL CHECK (
    status IN (
      'prepared', 'running', 'succeeded', 'failed', 'unknown', 'abandoned'
    )
  ),
  deadline_ms INTEGER NOT NULL,
  result BLOB,
  result_digest TEXT,
  external_id TEXT,
  error BLOB,
  error_digest TEXT,
  prepared_at_ms INTEGER NOT NULL,
  started_at_ms INTEGER,
  completed_at_ms INTEGER, attempt_identity TEXT,
  PRIMARY KEY (effect_key, attempt_number),
  FOREIGN KEY (effect_key) REFERENCES tamoz_effects(effect_key)
    ON DELETE CASCADE
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_effect_transitions (
  effect_key TEXT NOT NULL,
  transition_index INTEGER NOT NULL CHECK (transition_index >= 0),
  transition TEXT NOT NULL,
  attempt_number INTEGER,
  actor TEXT,
  evidence BLOB,
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY (effect_key, transition_index),
  FOREIGN KEY (effect_key) REFERENCES tamoz_effects(effect_key)
    ON DELETE CASCADE
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_store_heads (
  namespace TEXT NOT NULL,
  key TEXT NOT NULL,
  current_version INTEGER NOT NULL CHECK (current_version > 0),
  deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
  sensitive INTEGER NOT NULL CHECK (sensitive IN (0, 1)),
  updated_at_ms INTEGER NOT NULL,
  PRIMARY KEY (namespace, key)
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_store_versions (
  namespace TEXT NOT NULL,
  key TEXT NOT NULL,
  version INTEGER NOT NULL CHECK (version > 0),
  deleted INTEGER NOT NULL CHECK (deleted IN (0, 1)),
  sensitive INTEGER NOT NULL CHECK (sensitive IN (0, 1)),
  format_version INTEGER NOT NULL CHECK (format_version > 0),
  payload BLOB,
  payload_digest TEXT,
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY (namespace, key, version)
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_thread_tombstones (
  thread_id TEXT PRIMARY KEY,
  tombstone_id TEXT NOT NULL UNIQUE,
  expected_tips BLOB NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'purged')),
  effect_policy TEXT NOT NULL,
  authorization BLOB NOT NULL,
  report BLOB NOT NULL,
  report_digest TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  purge_after_ms INTEGER,
  FOREIGN KEY (thread_id) REFERENCES tamoz_threads(thread_id)
    ON DELETE CASCADE
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_deletion_receipts (
  tombstone_id TEXT PRIMARY KEY,
  thread_id_digest TEXT NOT NULL,
  report BLOB NOT NULL,
  report_digest TEXT NOT NULL,
  purged_at_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_schedules (
  schedule_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision > 0),
  definition_digest TEXT NOT NULL,
  payload TEXT NOT NULL,
  payload_digest TEXT NOT NULL,
  enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
  deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1)),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  PRIMARY KEY (schedule_id, revision)
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_occurrences (
  occurrence_id TEXT NOT NULL,
  schedule_id TEXT NOT NULL,
  schedule_revision INTEGER NOT NULL CHECK (schedule_revision > 0),
  nominal_fire_at_utc INTEGER NOT NULL,
  not_before INTEGER NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL CHECK (
    state IN ('due', 'claimed', 'enqueued', 'running', 'succeeded',
              'failed', 'cancelled', 'unknown', 'skipped', 'coalesced')
  ),
  fence INTEGER,
  owner TEXT,
  reason TEXT,
  payload_digest TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  PRIMARY KEY (occurrence_id)
) STRICT

-- tamoz migration boundary --
CREATE INDEX idx_tamoz_occurrences_due
  ON tamoz_occurrences(schedule_id, state, not_before)

-- tamoz migration boundary --
CREATE TABLE tamoz_digest_epoch (
  epoch INTEGER NOT NULL CHECK (epoch > 0)
) STRICT

-- tamoz migration boundary --
CREATE TABLE "tamoz_memory_index" (
  store_namespace TEXT NOT NULL,
  memory_id TEXT NOT NULL,
  record_version INTEGER NOT NULL CHECK (record_version > 0),
  layer TEXT NOT NULL,
  class TEXT NOT NULL,
  state TEXT NOT NULL,
  scopes_tenant TEXT NOT NULL,
  scopes_user TEXT NOT NULL,
  scopes_project TEXT NOT NULL,
  sensitivity TEXT NOT NULL CHECK (
    sensitivity IN ('public', 'internal', 'sensitive')
  ),
  valid_until_ms INTEGER,
  compatibility_graph TEXT NOT NULL,
  compatibility_behavior TEXT NOT NULL,
  statement_search TEXT,
  searchable INTEGER NOT NULL CHECK (searchable IN (0, 1)),
  scopes_situation_type TEXT,
  scopes_entity_type TEXT,
  scopes_entity_id TEXT,
  PRIMARY KEY (store_namespace, memory_id, record_version),
  CHECK (
    (scopes_situation_type IS NULL AND scopes_entity_type IS NULL AND scopes_entity_id IS NULL)
    OR
    (scopes_situation_type IS NOT NULL AND scopes_entity_type IS NOT NULL AND scopes_entity_id IS NOT NULL)
  )
) STRICT

-- tamoz migration boundary --
CREATE INDEX idx_tamoz_memory_index_scope
  ON tamoz_memory_index(
    store_namespace, state, scopes_tenant, scopes_user, scopes_project
  )

-- tamoz migration boundary --
CREATE INDEX idx_tamoz_memory_index_situation
  ON tamoz_memory_index(store_namespace, state, scopes_entity_type, scopes_tenant)

-- tamoz migration boundary --
CREATE TABLE tamoz_stream_verifications (
  tenant_id TEXT NOT NULL CHECK (length(tenant_id) > 0),
  intent_id TEXT NOT NULL,
  command_id TEXT,
  decision_id TEXT NOT NULL,
  episode_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  decision_digest TEXT NOT NULL CHECK (
    substr(decision_digest, 1, 7) = 'sha256:' AND
    length(decision_digest) = 71 AND
    substr(decision_digest, 8) NOT GLOB '*[^0-9a-f]*'
  ),
  episode TEXT NOT NULL CHECK (json_valid(episode) = 1),
  state TEXT NOT NULL CHECK (state IN ('awaiting', 'observed', 'reconciled')),
  outcome_id TEXT,
  outcome_digest TEXT CHECK (
    outcome_digest IS NULL OR (
      substr(outcome_digest, 1, 7) = 'sha256:' AND
      length(outcome_digest) = 71 AND
      substr(outcome_digest, 8) NOT GLOB '*[^0-9a-f]*'
    )
  ),
  verdict TEXT CHECK (
    verdict IS NULL OR verdict IN (
      'verified', 'refuted', 'inconclusive',
      'superseded_before_verification'
    )
  ),
  reconciliation_version INTEGER CHECK (
    reconciliation_version IS NULL OR reconciliation_version > 0
  ),
  source_authority TEXT,
  opened_at INTEGER NOT NULL CHECK (opened_at >= 0),
  reconciled_at INTEGER CHECK (reconciled_at IS NULL OR reconciled_at >= opened_at),
  learnable INTEGER NOT NULL DEFAULT 0 CHECK (learnable IN (0, 1)),
  CHECK (
    (state = 'awaiting' AND outcome_id IS NULL AND outcome_digest IS NULL AND
     verdict IS NULL AND reconciliation_version IS NULL AND
     source_authority IS NULL AND reconciled_at IS NULL AND learnable = 0)
    OR
    (state = 'observed' AND outcome_id IS NOT NULL AND outcome_digest IS NOT NULL AND
     command_id IS NOT NULL AND verdict IS NULL AND reconciliation_version IS NULL AND
     source_authority IS NULL AND reconciled_at IS NULL AND learnable = 0)
    OR
    (state = 'reconciled' AND command_id IS NOT NULL AND outcome_id IS NOT NULL AND
     outcome_digest IS NOT NULL AND verdict IS NOT NULL AND
     reconciliation_version IS NOT NULL AND source_authority IS NOT NULL AND
     reconciled_at IS NOT NULL AND
     (learnable = 0 OR (verdict IN ('verified', 'refuted') AND outcome_id IS NOT NULL)))
  ),
  PRIMARY KEY (tenant_id, intent_id)
) STRICT

-- tamoz migration boundary --
CREATE INDEX idx_tamoz_stream_verifications_state
  ON tamoz_stream_verifications(state, opened_at, tenant_id, intent_id)

-- tamoz migration boundary --
CREATE TABLE tamoz_artifacts (
  tenant_id TEXT NOT NULL,
  digest TEXT NOT NULL,
  media_type TEXT NOT NULL,
  bytes TEXT NOT NULL,
  retained_at INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, digest)
) STRICT

-- tamoz migration boundary --
CREATE INDEX idx_tamoz_artifacts_retained
  ON tamoz_artifacts(tenant_id, retained_at, digest)

-- tamoz migration boundary --
CREATE UNIQUE INDEX idx_tamoz_effect_attempt_identity ON tamoz_effect_attempts(attempt_identity)

-- tamoz migration boundary --
CREATE TABLE tamoz_approval_grants (
  key TEXT NOT NULL,
  scope TEXT NOT NULL,
  session_id TEXT NOT NULL,
  policy_rev TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  expires_at_ms INTEGER
) STRICT

-- tamoz migration boundary --
CREATE UNIQUE INDEX idx_tamoz_approval_grants_session
  ON tamoz_approval_grants(session_id, policy_rev, key, scope)

-- tamoz migration boundary --
CREATE TABLE tamoz_approval_decisions (
  decision_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  tool TEXT NOT NULL,
  verb TEXT NOT NULL,
  tier TEXT NOT NULL,
  rule_id TEXT NOT NULL,
  verdict TEXT NOT NULL,
  reason TEXT NOT NULL,
  evidence TEXT,
  policy_rev TEXT NOT NULL,
  argv_digest TEXT NOT NULL,
  targets_digest TEXT NOT NULL,
  step_scope TEXT NOT NULL DEFAULT '',
  grant_scopes TEXT,
  grant_key TEXT,
  answer TEXT,
  resolved_scope TEXT,
  actor_evidence TEXT,
  resolved_at_ms INTEGER,
  grant_created_at_ms INTEGER,
  grant_expires_at_ms INTEGER,
  created_at_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_approval_active_policy (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  policy_path TEXT NOT NULL,
  policy_rev TEXT NOT NULL,
  updated_at_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
CREATE INDEX idx_tamoz_approval_decisions_reuse
  ON tamoz_approval_decisions(session_id, argv_digest, targets_digest, step_scope, created_at_ms)

-- tamoz migration boundary --
CREATE TABLE tamoz_approval_mode_switches (
  switch_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  from_rev TEXT NOT NULL,
  to_rev TEXT NOT NULL,
  profile_name TEXT NOT NULL,
  ts_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
CREATE VIRTUAL TABLE tamoz_memory_fts USING fts5(
  store_namespace UNINDEXED,
  memory_id UNINDEXED,
  statement,
  tokenize = 'unicode61'
)

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_approval_prompts (
  reference_digest TEXT NOT NULL PRIMARY KEY,
  surface_id TEXT,
  surface_revision INTEGER CHECK (surface_revision IS NULL OR surface_revision > 0),
  thread_id TEXT NOT NULL,
  occurrence_id TEXT NOT NULL,
  interrupt_digest TEXT NOT NULL,
  correspondent_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  prompt_receipt TEXT,
  status TEXT NOT NULL CHECK (status IN ('inactive', 'active', 'consumed')),
  created_at_ms INTEGER NOT NULL,
  activated_at_ms INTEGER,
  consumed_at_ms INTEGER,
  expires_at_ms INTEGER NOT NULL
, required_evidence TEXT) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_bindings (
  surface_id TEXT NOT NULL,
  correspondent_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'revoked')),
  bound_by TEXT NOT NULL,
  bound_at_ms INTEGER NOT NULL,
  version INTEGER NOT NULL CHECK (version > 0),
  revocation_reason TEXT,
  PRIMARY KEY (surface_id, correspondent_id, version)
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_conversations (
  surface_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  surface_revision INTEGER NOT NULL CHECK (surface_revision > 0),
  thread_id TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  threading TEXT NOT NULL CHECK (threading IN ('conversation', 'per_message')),
  bound_at_ms INTEGER NOT NULL,
  version INTEGER NOT NULL CHECK (version > 0),
  generation INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (surface_id, conversation_id)
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_decisions (
  decision_id TEXT NOT NULL PRIMARY KEY,
  thread_id TEXT NOT NULL,
  occurrence_id TEXT NOT NULL,
  interrupt_digest TEXT NOT NULL,
  direction TEXT NOT NULL CHECK (direction IN ('approve', 'deny')),
  actor_kind TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  source TEXT NOT NULL,
  decided_at_ms INTEGER NOT NULL,
  expires_at_ms INTEGER NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'claimed', 'consumed')),
  claim_owner TEXT,
  claim_fence INTEGER CHECK (claim_fence IS NULL OR claim_fence > 0),
  claim_expires_at_ms INTEGER,
  consumed_at_ms INTEGER,
  evidence TEXT,
  reason TEXT,
  CHECK ((actor_kind = 'os_user' AND source = 'cli') OR
         (source NOT IN ('cli', 'os') AND length(source) BETWEEN 2 AND 32 AND
          source NOT GLOB '*[^a-z0-9_]*' AND substr(source, 1, 1) BETWEEN 'a' AND 'z' AND
          actor_kind = source || '_user'))
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_delivery_pacing (
  surface_id TEXT NOT NULL,
  scope TEXT NOT NULL,
  next_allowed_at_ms INTEGER NOT NULL CHECK (next_allowed_at_ms >= 0),
  PRIMARY KEY (surface_id, scope)
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_gaps (
  gap_id TEXT NOT NULL PRIMARY KEY,
  surface_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (
    kind IN ('expired_control', 'coalesced_control', 'capacity_refused')
  ),
  reason TEXT NOT NULL,
  text TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_inbound (
  surface_id TEXT NOT NULL,
  surface_revision INTEGER NOT NULL CHECK (surface_revision > 0),
  stream_id TEXT NOT NULL CHECK (length(stream_id) BETWEEN 3 AND 256),
  update_id INTEGER NOT NULL CHECK (update_id >= 0),
  raw_payload_hash TEXT NOT NULL,
  parser_version INTEGER NOT NULL CHECK (parser_version > 0),
  kind TEXT NOT NULL CHECK (
    kind IN ('text', 'command', 'callback', 'membership', 'attachment', 'unsupported')
  ),
  correspondent_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  disposition TEXT NOT NULL CHECK (
    disposition IN ('request', 'decision', 'ignored', 'rejected', 'quarantined')
  ),
  reason TEXT NOT NULL,
  request_id TEXT,
  decision_id TEXT,
  observed_at_ms INTEGER NOT NULL,
  ingested_at_ms INTEGER NOT NULL,
  conflict_count INTEGER NOT NULL DEFAULT 0,
  last_conflict_digest TEXT,
  PRIMARY KEY (surface_id, stream_id, update_id, raw_payload_hash)
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_outbox (
  delivery_id TEXT NOT NULL PRIMARY KEY,
  surface_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (
    kind IN ('accepted', 'answer', 'approval_request', 'failed',
             'stopped', 'blocked', 'control')
  ),
  operation TEXT NOT NULL CHECK (operation IN ('send_message', 'edit_message')),
  text TEXT NOT NULL,
  part_index INTEGER NOT NULL CHECK (part_index >= 0),
  part_count INTEGER NOT NULL CHECK (part_count > 0),
  markup TEXT,
  reply_to INTEGER,
  journaled INTEGER NOT NULL CHECK (journaled IN (0, 1)),
  content_digest TEXT NOT NULL,
  render_version INTEGER NOT NULL CHECK (render_version > 0),
  expires_at_ms INTEGER,
  status TEXT NOT NULL CHECK (
    status IN ('pending', 'claimed', 'succeeded', 'failed', 'unknown')
  ),
  claim_owner TEXT,
  claim_fence INTEGER CHECK (claim_fence IS NULL OR claim_fence > 0),
  claim_expires_at_ms INTEGER,
  effect_key TEXT,
  effect_execution_id TEXT,
  receipt TEXT,
  send_started_at_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
, request_id TEXT) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_pairing_challenges (
  challenge_digest TEXT NOT NULL PRIMARY KEY,
  surface_id TEXT NOT NULL,
  correspondent_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'consumed')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  expires_at_ms INTEGER NOT NULL,
  created_at_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_poll_state (
  stream_id TEXT NOT NULL PRIMARY KEY CHECK (length(stream_id) BETWEEN 3 AND 256),
  surface_id TEXT NOT NULL,
  next_offset INTEGER CHECK (next_offset IS NULL OR next_offset >= 0),
  poller_owner_id TEXT,
  poller_fence INTEGER CHECK (poller_fence IS NULL OR poller_fence > 0),
  poller_expires_at_ms INTEGER,
  updated_at_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_requests (
  request_id TEXT NOT NULL PRIMARY KEY,
  surface_id TEXT NOT NULL,
  surface_revision INTEGER NOT NULL CHECK (surface_revision > 0),
  conversation_id TEXT NOT NULL,
  thread_id TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  reservation INTEGER NOT NULL CHECK (reservation > 0),
  projection_state TEXT NOT NULL,
  cancellation_requested_at_ms INTEGER,
  cancellation_observed_at_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
CREATE TABLE tamoz_comms_surfaces (
  surface_id TEXT NOT NULL PRIMARY KEY,
  revision INTEGER NOT NULL CHECK (revision > 0),
  definition_digest TEXT NOT NULL,
  descriptor_json TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
) STRICT

-- tamoz migration boundary --
INSERT INTO tamoz_digest_epoch VALUES (1)

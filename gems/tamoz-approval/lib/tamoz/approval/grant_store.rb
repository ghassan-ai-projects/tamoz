# frozen_string_literal: true

module Tamoz
  module Approval
    # Port: durable or in-memory store for issued grants. Lookup is an exact
    # tuple match on (key, scope, session_id, policy_rev); expiry filtering
    # belongs to the Engine's single clock, not here. Callers are the worker
    # poll thread and session teardown; inserts of the same resolution replay
    # never happen because resolve records before it inserts.
    class GrantStore
      def lookup(key:, scope:, session_id:, policy_rev:)
        raise NotImplementedError
      end

      def insert(grant)
        raise NotImplementedError
      end

      def delete_by_session(session_id)
        raise NotImplementedError
      end
    end

    # In-memory implementation for tests and the one-shot runtime.
    class MemoryGrantStore < GrantStore
      def initialize
        @grants = []
        @mutex = Mutex.new
      end

      def lookup(key:, scope:, session_id:, policy_rev:)
        @mutex.synchronize do
          @grants.find do |grant|
            grant.scope == scope &&
              grant.session_id == session_id &&
              grant.policy_rev == policy_rev &&
              grant.key == key
          end
        end
      end

      def insert(grant)
        @mutex.synchronize do
          @grants << grant
        end
        nil
      end

      def delete_by_session(session_id)
        @mutex.synchronize do
          @grants.reject! { |grant| grant.session_id == session_id }
        end
        nil
      end

      def size
        @mutex.synchronize { @grants.size }
      end
    end
  end
end

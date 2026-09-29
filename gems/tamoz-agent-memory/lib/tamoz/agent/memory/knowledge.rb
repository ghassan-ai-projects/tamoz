# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # Knowledge written and removed on the user's own word. The authority for a
      # write is structural: the quote must be a whole clause of a message the user
      # sent, so a file, a tool result, guidance, or recalled memory can never be the
      # source of a durable fact, however the model was persuaded to call it. Every
      # write is idempotent, so a replayed tool call changes nothing twice.
      class Knowledge
        MIN_QUOTE_BYTES = 8
        KEY_PATTERN = /\A[a-z0-9][a-z0-9._-]{0,63}\z/
        # A quote must start and end at a clause boundary, so "deploy on Fridays" cannot be
        # cut out of "never deploy on Fridays".
        CLAUSE_START = /(?:\A|[.!?;:,(—–-]|\A["'])\s*["']?\z/
        CLAUSE_END = /\A["']?\s*(?:\z|[.!?;:,)—–-])/
        WORD = /[[:alnum:]]{4,}/

        def initialize(engine)
          @engine = engine
        end

        # Stores the quote itself (never a paraphrase) as :reported Knowledge. With a
        # key, a later quote for the same key in the same scope becomes a new version of
        # the same record, so exactly one is active.
        # rubocop:disable Metrics/ParameterLists -- the tool's arguments plus the caller's identity
        def remember(quote:, user_messages:, owner:, project:, session:, key: nil, scope: :project)
          statement = normalize(quote)
          message = clause_source(statement, user_messages)
          reason = refusal_reason(statement, message, key)
          return refused(reason) if reason

          project = '*' if scope.to_sym == :user
          memory_id = identity(owner, project, key ? "key\n#{key}" : "statement\n#{statement}")
          source = { 'identity' => "user-message:#{session}", 'digest' => Digest::SHA256.hexdigest(message),
                     'observed_at' => @engine.clock.call.to_i }
          existing = current(memory_id)
          return restate(existing, statement, source, owner) if existing

          @engine.admission.admit_owner_request(
            statement:, owner:, authority: 'owner', memory_id:, subject_key: key&.to_s, source_ref: source,
            scopes: { 'tenant' => @engine.tenant, 'user' => owner, 'project' => project, 'session' => session }
          )
        end
        # rubocop:enable Metrics/ParameterLists

        # Tombstones the record named by id or key when a user message asks for it: the
        # quote must be the user's words and must name the record (its key, or two of its
        # words), so an unrelated sentence cannot delete an unrelated fact.
        def forget(target:, quote:, user_messages:, owner:, project:)
          statement = normalize(quote)
          return refusal('quote_not_from_user') unless source_message(statement, user_messages)

          record = resolve(target.to_s, owner, project)
          return refusal('not_found') unless record
          return refusal('quote_does_not_name_it') unless names?(statement, record)
          return { 'forgotten' => true, 'memory_id' => record.memory_id, 'already' => true } unless record.eligible?

          @engine.lifecycle.delete(memory_id: record.memory_id, actor: owner, reason: 'the user asked to forget it')
                 .merge('forgotten' => true)
        end

        private

        def refusal_reason(statement, message, key)
          return 'quote_not_from_user' unless message
          return 'invalid_key' if key && !key.to_s.match?(KEY_PATTERN)

          'secret_shaped' if Surface.secret_shaped?(statement)
        end

        def restate(record, statement, source, owner)
          return Admission::AdmissionResult.new(record:, accepted: true) if
            record.eligible? && record.statement == statement

          corrected = @engine.lifecycle.correct(memory_id: record.memory_id, statement:, actor: owner,
                                                reason: 'the user restated it', source_refs: [source])
          Admission::AdmissionResult.new(record: corrected, accepted: true)
        end

        def resolve(target, owner, project)
          candidates = if target.start_with?('mem.')
                         [target]
                       else
                         [project, '*'].map { |scope| identity(owner, scope, "key\n#{target}") }
                       end
          candidates.filter_map { |id| current(id) }
                    .find { |record| record.owner == owner && [project, '*'].include?(record.scopes['project']) }
        end

        def current(memory_id)
          @engine.repository.fetch(@engine.namespace, 'knowledge', memory_id)&.fetch(:entry)&.value
        end

        def names?(statement, record)
          return true if record.subject_key && statement.include?(record.subject_key)

          (words(statement) & words(record.statement)).length >= 2
        end

        def words(text) = text.downcase.scan(WORD).uniq

        def identity(owner, project, subject) = MemoryRecordDigest.identity("#{owner}\n#{project}\n#{subject}")

        def clause_source(statement, messages)
          return nil if statement.bytesize < MIN_QUOTE_BYTES

          Array(messages).find { |message| clause_of?(normalize(message), statement) }
        end

        def clause_of?(message, statement)
          offset = 0
          while (index = message.index(statement, offset))
            return true if message[0...index].match?(CLAUSE_START) &&
                           message[(index + statement.length)..].match?(CLAUSE_END)

            offset = index + 1
          end
          false
        end

        def source_message(statement, messages)
          return nil if statement.bytesize < MIN_QUOTE_BYTES

          Array(messages).find { |message| normalize(message).include?(statement) }
        end

        def normalize(text) = text.to_s.gsub(/\s+/, ' ').strip

        def refused(reason) = Admission::AdmissionResult.new(rejected: true, reason:)

        def refusal(reason) = { 'forgotten' => false, 'reason' => reason }
      end
    end
  end
end

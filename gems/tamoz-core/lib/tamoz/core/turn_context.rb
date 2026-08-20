# frozen_string_literal: true

module Tamoz
  module Core
    # The bounded, surface-neutral context carried by a durable follow-up turn.
    # It contains only identity and conversation fragments; authority and
    # capability bindings remain owned by the durable thread.
    module TurnContext
      VERSION = 1
      DIGEST_DOMAIN = "tamoz.core.turn_context.v1\n"
      MAX_ID_BYTES = 256
      MAX_TEXT_BYTES = 16_384
      MAX_FRAGMENTS = 12
      MAX_FRAGMENT_TEXT_BYTES = 500
      MAX_CONTEXT_BYTES = 8_192
      ROLES = %w[user assistant].freeze

      module_function

      def task(thread_id:, request_id:, text:, fragments:)
        normalized_fragments = normalize_fragments(fragments)
        return { 'task' => normalize_text(text, 'task', MAX_TEXT_BYTES) } if normalized_fragments.empty?

        normalized_thread_id = normalize_text(thread_id, 'thread_id', MAX_ID_BYTES)
        normalized_request_id = normalize_text(request_id, 'request_id', MAX_ID_BYTES)
        context = {
          'version' => VERSION,
          'thread_id' => normalized_thread_id,
          'request_id' => normalized_request_id,
          'fragments' => normalized_fragments
        }
        context['digest'] = digest(context)
        task = { 'text' => normalize_text(text, 'task', MAX_TEXT_BYTES), 'context' => context }
        if Core.jcs(task).bytesize > MAX_CONTEXT_BYTES
          raise ConfigurationError,
                "turn context exceeds #{MAX_CONTEXT_BYTES} bytes"
        end

        { 'task' => Core.canonical(task) }
      end

      def fragments_from(context, thread_id:, request_id:)
        raise CheckpointCorruptionError, 'turn context must be an object' unless context.is_a?(Hash)

        validate_context_identity(context, thread_id:, request_id:)
        validate_context_digest(context)
        normalize_fragments(context.fetch('fragments'))
      rescue KeyError => e
        raise CheckpointCorruptionError, "turn context is missing #{e.key.inspect}"
      end

      def validate_context_identity(context, thread_id:, request_id:)
        expected = {
          'version' => VERSION,
          'thread_id' => normalize_text(thread_id, 'thread_id', MAX_ID_BYTES),
          'request_id' => normalize_text(request_id, 'request_id', MAX_ID_BYTES)
        }
        unknown = context.keys - %w[version thread_id request_id fragments digest]
        unless unknown.empty?
          raise CheckpointCorruptionError,
                "turn context has unknown keys: #{unknown.sort.join(', ')}"
        end

        expected.each do |key, value|
          raise CheckpointCorruptionError, "turn context #{key.inspect} does not match" unless context[key] == value
        end
      end

      def validate_context_digest(context)
        actual_digest = context.fetch('digest')
        unsigned_context = context.dup
        unsigned_context.delete('digest')
        return if actual_digest == digest(unsigned_context)

        raise CheckpointCorruptionError,
              'turn context digest is invalid'
      end

      def digest(context)
        Core.digest(DIGEST_DOMAIN, Core.canonical(context))
      end

      def normalize_fragments(fragments)
        unless fragments.is_a?(Array) && fragments.length <= MAX_FRAGMENTS
          raise ConfigurationError, "turn context fragments must be an Array of at most #{MAX_FRAGMENTS} entries"
        end

        fragments.map do |fragment|
          unless fragment.is_a?(Hash) && fragment.keys.sort == %w[role text]
            raise ConfigurationError, 'turn context fragments must contain only role and text'
          end

          role = fragment.fetch('role')
          raise ConfigurationError, 'turn context fragment role is not allowlisted' unless ROLES.include?(role)

          {
            'role' => role,
            'text' => normalize_text(
              fragment.fetch('text'), 'turn context fragment text', MAX_FRAGMENT_TEXT_BYTES
            )
          }
        end
      rescue KeyError => e
        raise ConfigurationError, "turn context fragment is missing #{e.key.inspect}"
      end

      def normalize_text(value, name, maximum)
        text = String(value).encode(Encoding::UTF_8)
        raise ConfigurationError, "#{name} cannot be empty" if text.empty?
        raise ConfigurationError, "#{name} exceeds #{maximum} bytes" if text.bytesize > maximum
        raise ConfigurationError, "#{name} must be valid UTF-8" unless text.valid_encoding?
        raise ConfigurationError, "#{name} cannot contain control characters" if text.match?(/[\u0000-\u001f\u007f]/u)

        text.freeze
      rescue EncodingError => e
        raise ConfigurationError, "#{name} must be valid UTF-8: #{e.message}"
      end
      private_class_method(
        :normalize_fragments, :normalize_text, :validate_context_identity, :validate_context_digest
      )
    end
  end
end

# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module ContextEngine
    # The append-only log messages are derived from; a replacement entry shadows a range and renders in its place.
    module Surface
      KINDS = %w[runtime guidance user assistant tool_result system_update checkpoint].freeze
      FIELDS = %w[tool_call_id name replaces pinned spilled source].freeze

      module_function

      # Tool calls go to the store like text; the entry keeps only their ids, so a large
      # create_file argument never sits in checkpointed state.
      # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists -- an entry's text and tool calls go to the store in one place
      def entry(kind:, seq:, text:, store:, tool_calls: nil, **fields)
        raise Error, "unknown surface entry kind #{kind.inspect}" unless KINDS.include?(kind)
        raise Error, 'surface seq must be a non-negative Integer' unless seq.is_a?(Integer) && seq >= 0
        raise Error, 'surface text must be a String' unless text.is_a?(String)

        record = { 'seq' => seq, 'kind' => kind, 'bytes' => text.bytesize }
        record['text_ref'] = retain(store, text) unless text.empty?
        record.merge!(calls_record(store, tool_calls)) if tool_calls && !tool_calls.empty?
        record.merge!(optional_fields(fields))
        validate_replaces!(record)
        Tamoz::Core.deep_freeze(record)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/ParameterLists

      def optional_fields(fields)
        fields.each_with_object({}) do |(key, value), accepted|
          name = String(key)
          raise Error, "surface entry does not accept #{name.inspect}" unless FIELDS.include?(name)

          accepted[name] = value unless value.nil?
        end
      end

      def retain(store, text)
        digest = "sha256:#{Digest::SHA256.hexdigest(text)}"
        store.retain(digest:, bytes: text, media_type: 'text/plain')
        digest
      end

      def calls_record(store, calls)
        { 'tool_calls_ref' => retain(store, JSON.generate(calls)), 'tool_call_ids' => calls.map do |call|
          call.fetch('id')
        end }
      end

      def tool_calls(entry, resolve)
        reference = entry['tool_calls_ref']
        reference ? JSON.parse(resolve.call(reference) || raise(Error, "tool calls #{reference} are unavailable")) : []
      end

      def resolver(store) = ->(reference) { store.resolve(reference)&.fetch('bytes') }

      def text(entry, resolve)
        reference = entry['text_ref']
        return '' unless reference

        resolved = resolve.call(reference)
        raise Error, "surface text #{reference} is unavailable" unless resolved.is_a?(String)

        resolved
      end

      def position(entry) = entry['replaces']&.first || entry.fetch('seq')

      def reach(entry) = entry['replaces']&.last || entry.fetch('seq')

      def next_seq(entries) = (entries.map { |entry| entry.fetch('seq') }.max || -1) + 1

      def visible(entries)
        positioned = []
        entries.sort_by { |entry| entry.fetch('seq') }.each do |entry|
          if (range = entry['replaces'])
            positioned.reject! { |at, _| at.between?(*range) }
          end
          positioned << [position(entry), entry]
        end
        positioned.sort_by(&:first).map(&:last)
      end

      def messages(entries, header:, resolve:)
        [header.system_message] + visible(entries).map { |entry| message(entry, resolve) }
      end

      def message(entry, resolve)
        body = text(entry, resolve)
        case entry.fetch('kind')
        when 'assistant' then assistant_message(body, tool_calls(entry, resolve))
        when 'tool_result' then { 'role' => 'tool', 'tool_call_id' => entry.fetch('tool_call_id'), 'content' => body }
        else { 'role' => 'user', 'content' => body }
        end
      end

      def assistant_message(body, calls)
        message = { 'role' => 'assistant', 'content' => body.empty? ? nil : body }
        return message if calls.empty?

        message.merge(
          'tool_calls' => calls.map do |call|
            {
              'id' => call.fetch('id'),
              'type' => 'function',
              'function' => { 'name' => call.fetch('name'), 'arguments' => call.fetch('arguments') }
            }
          end
        )
      end

      # True when no tool call in `visible_entries[0...index]` is left unanswered
      # inside that span, so a cut at `index` never separates a call from its result.
      def balanced_cut?(visible_entries, index)
        pending = []
        visible_entries.first(index).each do |entry|
          case entry.fetch('kind')
          when 'assistant' then pending.concat(Array(entry['tool_call_ids']))
          when 'tool_result' then pending.delete(entry.fetch('tool_call_id'))
          end
        end
        pending.empty?
      end

      def validate_replaces!(record)
        range = record['replaces']
        return unless range

        valid = range.is_a?(Array) && range.length == 2 && range.all?(Integer) && range.first <= range.last &&
                range.last < record.fetch('seq')
        raise Error, "replaces must be [first_seq, last_seq] before the entry's own seq" unless valid
      end
      private_class_method :validate_replaces!, :optional_fields, :calls_record
    end
  end
end

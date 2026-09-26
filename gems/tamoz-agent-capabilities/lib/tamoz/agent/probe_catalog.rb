# frozen_string_literal: true

module Tamoz
  module Agent
    # Operator-declared read-only probes (`sources.probes`); a probe that could mutate or escape its scope never loads.
    class ProbeCatalog
      class Error < Tamoz::Agent::Error; end

      DIGEST_PREFIX = "tamoz.agent.probes.v1\n"
      NAME = /\Aprobe_[a-z0-9_]{1,58}\z/
      TARGET_KEY = /\A[a-z0-9_]{1,64}\z/
      PLACEHOLDER = /\{([a-z]+)\.([a-z0-9_]+)\}/
      WINDOW_KEYS = %w[from until].freeze
      FREE_TYPES = %w[string integer enum sql_select].freeze
      MAX_RESULT_BYTES = 64 * 1024
      MIN_RESULT_BYTES = 256
      MAX_DESCRIPTION_BYTES = 1024
      MAX_STRING_BYTES = 4096
      MAX_LOOKBACK_MINUTES = 1440

      Probe = Data.define(:name, :description, :server, :tool, :pinned, :free, :max_result_bytes) do
        def backing_id = "mcp:#{server}/#{tool}"
        def targeted? = placeholders.any? { |scope, _| scope == 'target' }
        def windowed? = placeholders.any? { |scope, _| scope == 'window' }

        def placeholders
          strings = pinned.values.flatten.grep(String) +
                    free.values.flat_map { |slot| Array(slot['values']) }
          strings.flat_map { |text| text.scan(PLACEHOLDER) }.uniq
        end

        # The model-facing slots. An episode's target and window come from the verified snapshot,
        # so only a session turn is offered them.
        def episode_schema = object_schema(free.to_h { |key, slot| [key, slot_schema(slot)] })

        def session_schema(targets)
          properties = episode_schema.fetch('properties').dup
          properties['target'] = { 'type' => 'string', 'enum' => targets } if targeted?
          properties['lookback_minutes'] = lookback_schema if windowed?
          object_schema(properties)
        end

        private

        def slot_schema(slot)
          case slot.fetch('free')
          when 'integer' then { 'type' => 'integer', 'minimum' => slot['min'], 'maximum' => slot['max'] }.compact
          when 'enum' then { 'type' => 'string', 'enum' => slot.fetch('values') }
          else { 'type' => 'string', 'maxLength' => slot.fetch('max_bytes') }
          end
        end

        def object_schema(properties)
          { 'type' => 'object', 'additionalProperties' => false, 'properties' => properties,
            'required' => properties.keys }
        end

        def lookback_schema = { 'type' => 'integer', 'minimum' => 1, 'maximum' => MAX_LOOKBACK_MINUTES }
      end

      # Whether a model-supplied value fits its free slot.
      def self.free_value?(slot, value)
        case slot.fetch('free')
        when 'integer' then value.is_a?(Integer) && value.between?(slot.fetch('min'), slot.fetch('max'))
        when 'enum' then slot.fetch('values').include?(value)
        when 'sql_select' then bounded_string?(slot, value) && read_only_query?(value)
        else bounded_string?(slot, value)
        end
      end

      def self.bounded_string?(slot, value) = value.is_a?(String) && value.bytesize <= slot.fetch('max_bytes')

      def self.read_only_query?(query)
        GovernedDatabaseSource.validate_query(query)
        true
      rescue Tamoz::Tools::ToolError
        false
      end

      attr_reader :probes, :targets, :digest

      # servers: the configured MCP server settings, keyed by server id.
      def initialize(settings, servers:)
        @targets = load_targets(settings.fetch('targets', {}))
        @probes = load_probes(settings.fetch('probes', nil), servers)
        @digest = Tamoz::Core.digest(DIGEST_PREFIX, { 'targets' => @targets, 'probes' => @probes.values.map(&:to_h) })
        freeze
      rescue KeyError, TypeError => e
        raise Error, "sources.probes is malformed: #{e.message}"
      end

      def backing_servers = @probes.values.map(&:server).uniq.freeze

      def probe(name) = @probes[String(name)]

      private

      def load_targets(raw)
        mapping!(raw, 'sources.probes.targets')
        raw.to_h do |id, fields|
          mapping!(fields, "target #{id}")
          fields.each do |key, value|
            raise Error, "target #{id} key #{key.inspect} is invalid" unless key.is_a?(String) && key.match?(TARGET_KEY)
            raise Error, "target #{id}.#{key} must be a string" unless value.is_a?(String)
          end
          [String(id), fields.dup.freeze]
        end.freeze
      end

      def load_probes(raw, servers)
        raise Error, 'sources.probes.probes must be a non-empty list' unless raw.is_a?(Array) && !raw.empty?

        raw.each_with_object({}) do |entry, probes|
          probe = load_probe(entry, servers)
          raise Error, "probe #{probe.name} is declared twice" if probes.key?(probe.name)

          probes[probe.name] = probe
        end.freeze
      end

      def load_probe(entry, servers)
        mapping!(entry, 'probe')
        name = entry.fetch('name')
        unless name.is_a?(String) && name.match?(NAME)
          raise Error,
                "probe name #{name.inspect} must match #{NAME.source}"
        end

        server, tool = backing!(name, entry.fetch('backing'), servers)
        pinned, free = partition_arguments!(name, entry.fetch('arguments'))
        probe = Probe.new(name:, description: description!(name, entry.fetch('description')), server:, tool:,
                          pinned:, free:, max_result_bytes: result_bytes!(name, entry))
        check_placeholders!(probe)
        check_database_server!(probe, servers.fetch(server))
        probe
      end

      # A database server's governor keeps only `query` and `max_rows`, so any other argument would be dropped unseen.
      def check_database_server!(probe, settings)
        return unless settings['database']
        return if probe.pinned.empty? && probe.free.keys == ['query'] && probe.free.dig('query', 'free') == 'sql_select'

        raise Error, "probe #{probe.name} backs onto database server #{probe.server}; " \
                     'its only argument must be a sql_select slot named query'
      end

      def backing!(name, backing, servers)
        mapping!(backing, "probe #{name} backing")
        server = backing.fetch('server')
        tool = backing.fetch('tool')
        settings = servers[server]
        raise Error, "probe #{name} names MCP server #{server.inspect}, which is not configured" unless settings
        unless Array(settings['read_only_tools']).include?(tool)
          raise Error, "probe #{name} backs onto #{server}/#{tool}, which the operator has not declared read-only"
        end

        [server, tool]
      end

      def partition_arguments!(name, arguments)
        mapping!(arguments, "probe #{name} arguments")
        free, pinned = arguments.partition { |_key, value| value.is_a?(Hash) }.map(&:to_h)
        pinned.each { |key, value| pinned_value!(name, key, value) }
        free.each { |key, slot| free_slot!(name, key, slot) }
        reserved = free.keys & %w[target lookback_minutes]
        raise Error, "probe #{name} free argument #{reserved.first} is reserved" unless reserved.empty?

        [deep_freeze(pinned), deep_freeze(free)]
      end

      def pinned_value!(name, key, value)
        return if [String, Integer, Float, TrueClass, FalseClass].any? { |type| value.is_a?(type) }
        return if value.is_a?(Array) && value.all?(String)

        raise Error, "probe #{name} argument #{key} is neither a pinned value nor a free slot"
      end

      def free_slot!(name, key, slot)
        type = slot['free']
        unless FREE_TYPES.include?(type)
          raise Error,
                "probe #{name} argument #{key} has unknown free type #{type.inspect}"
        end

        case type
        when 'integer' then integer_slot!(name, key, slot)
        when 'enum' then enum_slot!(name, key, slot)
        else string_slot!(name, key, slot)
        end
      end

      def integer_slot!(name, key, slot)
        min = slot.fetch('min')
        max = slot.fetch('max')
        return if min.is_a?(Integer) && max.is_a?(Integer) && min <= max

        raise Error, "probe #{name} argument #{key} needs integer min <= max"
      end

      def enum_slot!(name, key, slot)
        values = slot.fetch('values')
        return if values.is_a?(Array) && !values.empty? && values.all?(String) && values.uniq == values

        raise Error, "probe #{name} argument #{key} needs a list of distinct string values"
      end

      def string_slot!(name, key, slot)
        max = slot.fetch('max_bytes')
        return if max.is_a?(Integer) && max.between?(1, MAX_STRING_BYTES)

        raise Error, "probe #{name} argument #{key} needs max_bytes between 1 and #{MAX_STRING_BYTES}"
      end

      def description!(name, text)
        return text.freeze if text.is_a?(String) && !text.strip.empty? && text.bytesize <= MAX_DESCRIPTION_BYTES

        raise Error, "probe #{name} needs a description of at most #{MAX_DESCRIPTION_BYTES} bytes"
      end

      def result_bytes!(name, entry)
        bytes = entry.fetch('max_result_bytes', MAX_RESULT_BYTES)
        return bytes if bytes.is_a?(Integer) && bytes.between?(MIN_RESULT_BYTES, MAX_RESULT_BYTES)

        raise Error, "probe #{name} max_result_bytes must be between #{MIN_RESULT_BYTES} and #{MAX_RESULT_BYTES}"
      end

      def check_placeholders!(probe)
        probe.placeholders.each do |scope, key|
          next if scope == 'target' && !@targets.empty? && @targets.values.all? { |fields| fields.key?(key) }
          next if scope == 'window' && WINDOW_KEYS.include?(key)

          raise Error, "probe #{probe.name} uses {#{scope}.#{key}}, which is not a target field or window bound"
        end
      end

      def mapping!(value, label)
        raise Error, "#{label} must be a mapping" unless value.is_a?(Hash)
      end

      def deep_freeze(value) = Tamoz::Core.deep_freeze(value)
    end
  end
end

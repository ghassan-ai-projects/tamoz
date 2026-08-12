# frozen_string_literal: true

module Tamoz
  module Graph
    class Compiler
      attr_reader :definition, :codec

      def initialize(
        definition,
        codec: StateCodec.new,
        checkpointer: MemoryCheckpointer.new,
        limits: Limits.new,
        **options
      )
        unless options.empty?
          raise GraphDefinitionError, "unknown compile options: #{options.keys.sort.inspect}"
        end

        @definition = definition
        @codec = codec
        @checkpointer = checkpointer
        @limits = limits
        validate_dependencies!
      end

      def compile
        validate!
        digest = Canonical.digest(descriptor, domain: "tamoz.graph.definition\n")
        Compiled.new(
          definition:,
          definition_digest: digest,
          codec:,
          checkpointer: @checkpointer,
          limits: @limits
        )
      end

      private

      def validate!
        raise GraphDefinitionError, "graph must declare at least one state channel" if definition.channels.empty?
        raise GraphDefinitionError, "graph must declare at least one node" if definition.nodes.empty?

        definition.edges.each do |source, target|
          validate_source!(source)
          validate_target!(target)
        end
        definition.branches.each do |branch|
          validate_source!(branch.source)
          branch.targets.each { |target| validate_target!(target) }
        end
        definition.nodes.each_value do |node|
          node.routes.each { |target| validate_target!(target) }
          declared = static_sources.key?(node.name)
          if node.routing == :dynamic && declared
            raise GraphDefinitionError,
                  "dynamic node #{node.name} cannot also have static or branch successors"
          end
          if node.routing == :additive && !declared
            raise GraphDefinitionError,
                  "additive node #{node.name} requires a static or branch successor"
          end
        end

        entries = definition.edges.select { |source, _target| source.equal?(START) }.map(&:last)
        raise GraphDefinitionError, "graph must have an edge from START" if entries.empty?

        reachable = reachability(entries)
        missing = definition.nodes.keys - reachable
        unless missing.empty?
          raise GraphDefinitionError, "unreachable nodes: #{missing.sort.inspect}"
        end

        terminal = reverse_reachable_from_end
        trapped = reachable - terminal
        unless trapped.empty?
          raise GraphDefinitionError, "nodes have no declared path to END: #{trapped.sort.inspect}"
        end
      end

      def validate_source!(source)
        return if source.equal?(START)
        return if definition.nodes.key?(source)

        raise GraphDefinitionError, "unknown edge/branch source #{source.inspect}"
      end

      def validate_dependencies!
        unless codec.respond_to?(:normalize) &&
               codec.respond_to?(:dump) &&
               codec.respond_to?(:load)
          raise GraphDefinitionError, "codec must implement normalize, dump, and load"
        end
        protocol = @checkpointer.respond_to?(:checkpoint_protocol_version) &&
               @checkpointer.checkpoint_protocol_version == CHECKPOINT_PROTOCOL_VERSION &&
               @checkpointer.respond_to?(:durable?)
        bound_contract = @checkpointer.respond_to?(:open_writer) &&
                         @checkpointer.respond_to?(:latest) &&
                         @checkpointer.respond_to?(:find) &&
                         @checkpointer.respond_to?(:history)
        unless protocol &&
               (bound_contract || @checkpointer.respond_to?(:bind_graph))
          raise GraphDefinitionError, "checkpointer does not implement the graph checkpoint contract"
        end
        unless @limits.is_a?(Limits)
          raise GraphDefinitionError, "limits must be a Tamoz::Graph::Limits value"
        end
      end

      def validate_target!(target)
        return if target.equal?(Tamoz::END)
        return if definition.nodes.key?(target)

        raise GraphDefinitionError, "unknown edge/branch target #{target.inspect}"
      end

      def reachability(entries)
        seen = {}
        pending = entries.dup
        index = 0
        while index < pending.length
          node = pending.fetch(index)
          index += 1
          next if node.equal?(Tamoz::END) || seen.key?(node)

          seen[node] = true
          pending.concat(target_map.fetch(node))
        end
        seen.keys.freeze
      end

      def reverse_reachable_from_end
        reverse = Hash.new { |hash, key| hash[key] = [] }
        target_map.each do |source, targets|
          targets.each { |target| reverse[target] << source }
        end
        terminal = {}
        pending = reverse.fetch(Tamoz::END, []).dup
        index = 0
        while index < pending.length
          node = pending.fetch(index)
          index += 1
          next if terminal.key?(node)

          terminal[node] = true
          reverse.fetch(node, []).each do |source|
            pending << source unless terminal.key?(source)
          end
        end
        terminal.keys
      end

      def declared_targets(node)
        target_map.fetch(node)
      end

      def target_map
        @target_map ||= begin
          targets_by_node = definition.nodes.to_h { |node, _spec| [node, []] }
          definition.edges.each do |source, target|
            targets_by_node.fetch(source) << target unless source.equal?(START)
          end
          definition.branches.each do |branch|
            targets_by_node.fetch(branch.source).concat(branch.targets)
          end
          definition.nodes.each do |node, spec|
            targets_by_node.fetch(node).concat(spec.routes)
          end
          targets_by_node.transform_values { |targets| targets.uniq.freeze }.freeze
        end.freeze
      end

      def static_sources
        @static_sources ||= begin
          sources = {}
          definition.edges.each do |source, _target|
            sources[source] = true unless source.equal?(START)
          end
          definition.branches.each { |branch| sources[branch.source] = true }
          sources.freeze
        end
      end

      def descriptor
        {
          "format_version" => 1,
          "name" => definition.name,
          "version" => definition.version,
          "channels" => definition.channels.values.map(&:descriptor).sort_by { |entry| entry.fetch("name") },
          "nodes" => definition.nodes.values.map(&:descriptor).sort_by { |entry| entry.fetch("name") },
          "edges" => definition.edges.map do |source, target|
            [
              source.equal?(START) ? "__start__" : source.to_s,
              target.equal?(Tamoz::END) ? "__end__" : target.to_s
            ]
          end.sort,
          "branches" => definition.branches.map(&:descriptor).sort_by { |entry| entry.fetch("name") }
        }
      end
    end

    private_constant :Compiler
  end
end

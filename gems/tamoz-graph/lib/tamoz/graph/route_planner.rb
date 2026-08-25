# frozen_string_literal: true

module Tamoz
  module Graph
    class RoutePlanner
      attr_reader :definition

      def initialize(definition:)
        @definition = definition
        freeze
      end

      def initial_frontier
        targets = definition.edges.filter_map do |source, target|
          target if source.equal?(START)
        end
        pull_frontier(targets, logical_step: 1)
      end

      def next_frontier(outcomes, candidate, logical_step:)
        pull_targets = []
        push_entries = []
        outcomes.each do |outcome|
          declared = resolve_routes(outcome.node, candidate)
          dynamic = outcome.goto || []
          node = definition.nodes.fetch(outcome.node)
          validate_routing_mode!(outcome.node, node, declared, dynamic)
          validate_dynamic_routes!(node, dynamic)

          add_routes(
            declared + dynamic,
            outcome:,
            pull_targets:,
            push_entries:,
            logical_step:
          )
        end

        (pull_frontier(pull_targets, logical_step:) + push_entries)
          .sort_by { |entry| entry.path }
          .freeze
      end

      private

      def resolve_routes(node, candidate)
        routes = definition.edges.filter_map do |source, target|
          target if source == node
        end
        definition.branches.each do |branch|
          next unless branch.source == node

          returned = branch.router.call(candidate)
          values = returned.is_a?(Array) ? returned : [returned]
          values.each do |value|
            target = route_target(value)
            unless declared_route?(branch.targets, target)
              raise InvalidUpdateError,
                    "branch #{branch.name} returned undeclared target #{target.inspect}"
            end
          end
          routes.concat(values)
        rescue InvalidUpdateError
          raise
        rescue StandardError => error
          raise InvalidUpdateError, "branch #{branch.name} failed: #{error.class}"
        end
        routes
      end

      def validate_routing_mode!(node_key, node, declared, dynamic)
        return if dynamic.empty?

        if node.routing == :static
          raise InvalidUpdateError,
                "static node #{node_key} returned dynamic routing"
        end
        return if declared.empty? || node.routing == :additive

        raise InvalidUpdateError,
              "node #{node_key} combines routes without routing: :additive"
      end

      def add_routes(routes, outcome:, pull_targets:, push_entries:, logical_step:)
        effective_keys = {}
        routes.each_with_index do |route, index|
          if route.equal?(Tamoz::END)
            next
          elsif route.is_a?(Send)
            validate_target!(route.node)
            key = route.key || index.to_s
            if effective_keys.key?(key)
              raise InvalidUpdateError,
                    "colliding Send key #{key.inspect} from task #{outcome.task_id}"
            end
            effective_keys[key] = true
            push_entries << Frontier.new(
              node: route.node,
              kind: :push,
              path: [*outcome.path, "send", route.node.to_s, key],
              input: route.input,
              logical_step:
            )
          else
            target = Identifier.symbol(route, name: "route target")
            validate_target!(target)
            pull_targets << target
          end
        end
      end

      def validate_dynamic_routes!(node, routes)
        routes.each do |route|
          target = route_target(route)
          unless declared_route?(node.routes, target)
            raise InvalidUpdateError,
                  "node #{node.name} returned undeclared dynamic route #{target.inspect}"
          end
        end
      end

      def pull_frontier(targets, logical_step:)
        targets.reject { |target| target.equal?(Tamoz::END) }
               .uniq
               .sort_by(&:to_s)
               .map do |target|
          validate_target!(target)
          Frontier.new(
            node: target,
            kind: :pull,
            path: ["pull", logical_step.to_s, target.to_s],
            logical_step:
          )
        end
      end

      def route_target(route)
        route.is_a?(Send) ? route.node : route
      end

      def declared_route?(routes, target)
        routes.any? { |declared| declared.equal?(target) || declared == target }
      end

      def validate_target!(target)
        return if target.equal?(Tamoz::END)
        return if definition.nodes.key?(target)

        raise InvalidUpdateError, "route targets unknown node #{target.inspect}"
      end
    end

    private_constant :RoutePlanner
  end
end

# frozen_string_literal: true

module Tamoz
  module Graph
    class Branch
      MAX_TARGETS = 65_536

      attr_reader :source, :name, :version, :targets, :router

      def initialize(source:, name:, version:, targets:, router:)
        @source = Identifier.symbol(source, name: "branch source")
        @name = Identifier.string(name || "#{@source}.branch", name: "branch name")
        @version = Identifier.version(version, name: "branch version")
        raise GraphDefinitionError, "branch targets must be a non-empty Array" unless targets.is_a?(Array) &&
                                                                                      !targets.empty?
        if targets.length > MAX_TARGETS
          raise GraphDefinitionError, "branch exceeds #{MAX_TARGETS} targets"
        end
        @targets = targets.map { |target| normalize_target(target) }.uniq.freeze
        raise GraphDefinitionError, "branch router must respond to call" unless router.respond_to?(:call)

        @router = router
        freeze
      end

      def descriptor
        {
          "source" => source.to_s,
          "name" => name,
          "version" => version,
          "targets" => targets.map { |target| target.equal?(Tamoz::END) ? "__end__" : target.to_s }.sort
        }
      end

      private

      def normalize_target(target)
        return Tamoz::END if target.equal?(Tamoz::END)

        Identifier.symbol(target, name: "branch target")
      end

      private_constant :MAX_TARGETS
    end
  end
end

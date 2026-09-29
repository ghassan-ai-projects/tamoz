# frozen_string_literal: true

require "json"
require "sqlite3"

module Agenteval
  module SubagentPack
    # What a session durably recorded: the parent's final state, each child's final state, the effect journal's
    # (namespace, operation) rows, and the artifact texts surface entries point at. Graders read this and nothing the
    # agent said (bar F3). `read` builds it from a real session store; controls build it by hand.
    Record = Data.define(:parent, :children, :journal, :texts) do
      def self.read(path)
        database = SQLite3::Database.new(path, readonly: true)
        latest = database.execute("SELECT namespace, CAST(payload AS TEXT) FROM tamoz_checkpoints ORDER BY namespace, sequence")
                         .group_by(&:first).transform_values { |rows| SessionChain.decode_state(rows.last.last) }
        journal = database.execute("SELECT namespace, operation FROM tamoz_effects")
        texts = database.execute("SELECT digest, CAST(bytes AS TEXT) FROM tamoz_artifacts").to_h
        new(parent: latest.fetch("[]", {}), children: latest.select { |namespace, _| namespace.include?("subgraph") }.values,
            journal:, texts:)
      ensure
        database&.close
      end

      def trace = Array(parent["work_trace"])
      def delegations = trace.count { |event| event["event"] == "subagent_started" }
      def finished = trace.select { |event| event["event"] == "subagent_finished" }
      def text(entry) = entry["text_ref"] ? texts.fetch(entry["text_ref"], "") : ""

      def child_reads
        children.flat_map { |child| Hash(child["work_observations"]).select { |_, seen| seen["read"] }.keys }.uniq
      end

      # Paths the parent read after its first delegation answered.
      def parent_reads_after_delegation
        entries = Array(parent["work_entries"])
        first = entries.find { |entry| entry["name"] == "delegate" && entry["kind"] == "tool_result" }
        return [] unless first

        entries.select { |entry| entry["kind"] == "tool_result" && entry["name"] == "read_file" && entry["seq"] > first["seq"] }
               .filter_map { |entry| text(entry)[/\AFile: (.+)$/, 1] }.uniq
      end

      def parent_changes = Array(parent["work_changes"]).uniq
    end
  end
end

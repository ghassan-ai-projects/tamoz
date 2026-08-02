# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"

module Tamoz
  module Evals
    module Harness
      # DR-3 per-cell memory store (C4/E7). One store directory per
      # (case, treatment) cell:
      #
      #   index.json — every record's metadata + searchable keys, plus PUBLIC
      #                record bodies;
      #   vault.json — RESTRICTED record bodies, obfuscated, opened only by
      #                `read` (instrumented via `decrypt_reads`).
      #
      # `scan` opens index.json only, so a scan that matches a restricted record
      # never decrypts it (P11-B decryption-boundary property, C8). The seed
      # digest pins both files, so `seed_intact?` detects cross-treatment
      # contamination before a run (E7) and store drift after a run (E5).
      class MemoryStore
        INDEX_FILE = "index.json"
        VAULT_FILE = "vault.json"
        OBFUSCATION_BYTE = 0x5A
        RESTRICTED = "restricted"

        attr_reader :path, :decrypt_reads, :absorb_refusals, :seed_digest

        def initialize(path)
          @path = File.expand_path(path)
          @directory = File.dirname(@path)
          @decrypt_reads = 0
          @absorb_refusals = 0
          @seed_digest = nil
        end

        def self.seed(path, fixtures)
          store = new(path)
          store.seed(fixtures)
          store
        end

        def seed(fixtures)
          FileUtils.mkdir_p(@directory)
          write_stable(INDEX_FILE, {"records" => fixtures.map { |record| index_entry(record) }})
          write_stable(VAULT_FILE, {"records" => restricted_bodies(fixtures)})
          @seed_digest = digest
          @seed_digest
        end

        # Content digest over both files; deterministic across identical seeds.
        def digest
          "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.dump(document))}"
        end

        def seed_intact?
          @seed_digest && digest == @seed_digest
        end

        # Scan the INDEX only. Returns matching PUBLIC record ids and the ids of
        # RESTRICTED records whose searchable keys matched (matched but
        # withheld). Restricted bodies are never read here, so the decryption
        # boundary holds even when the filter path is genuinely exercised (C8).
        def scan(query)
          index = read_index
          matched = []
          matched_restricted = []
          index.fetch("records").each do |entry|
            next unless entry.fetch("match_keys").any? { |key| query.include?(key) }

            if entry.fetch("classification") == RESTRICTED
              matched_restricted << entry.fetch("memory_id")
            else
              matched << entry.fetch("memory_id")
            end
          end
          DeepFreeze.call("matched_ids" => matched, "matched_restricted_ids" => matched_restricted)
        end

        # Index metadata (no bodies). Never touches the vault.
        def metadata(memory_id)
          entry = read_index.fetch("records").find do |candidate|
            candidate.fetch("memory_id") == memory_id
          end
          raise ExecutionError, "memory store has no record #{memory_id}" unless entry

          DeepFreeze.call(entry)
        end

        # Full record. Reading a RESTRICTED record decrypts it (instrumented).
        def record(memory_id)
          entry = metadata(memory_id)
          return entry if entry.fetch("classification") != RESTRICTED

          @decrypt_reads += 1
          DeepFreeze.call(entry.merge("content" => unobfuscate(read_vault.fetch("records").fetch(memory_id))))
        end

        # Admission boundary. Prompt-sourced content is always refused; nothing
        # from a prompt is ever written, so the store stays seed-stable in CI.
        def absorb(_fields, prompt_sourced:)
          if prompt_sourced
            @absorb_refusals += 1
            return :refused
          end

          raise ExecutionError, "memory admission is a live-layer operation"
        end

        # Records absorbed from prompt content. Structurally zero: `absorb` with
        # `prompt_sourced: true` refuses and never writes.
        def absorbed_count
          0
        end

        private

        def document
          {"index" => read_index, "vault" => read_vault}
        end

        def read_index
          read_json(INDEX_FILE)
        end

        def read_vault
          read_json(VAULT_FILE)
        end

        def index_entry(record)
          entry = {
            "memory_id" => record.fetch("memory_id"),
            "record_version" => record.fetch("record_version"),
            "epoch" => record.fetch("epoch"),
            "classification" => record.fetch("classification"),
            "match_keys" => record.fetch("match_keys")
          }
          if record.fetch("classification") == RESTRICTED
            entry["vaulted"] = true
          else
            entry["content"] = record.fetch("content")
          end
          entry
        end

        def restricted_bodies(fixtures)
          fixtures.each_with_object({}) do |record, bodies|
            next unless record.fetch("classification") == RESTRICTED

            bodies[record.fetch("memory_id")] = obfuscate(record.fetch("content"))
          end
        end

        def obfuscate(content)
          plain = CanonicalJSON.dump(content).b
          encoded = plain.bytes.map { |byte| byte ^ OBFUSCATION_BYTE }.pack("C*")
          Base64.strict_encode64(encoded)
        end

        def unobfuscate(payload)
          raw = Base64.strict_decode64(payload)
          bytes = raw.bytes.map { |byte| byte ^ OBFUSCATION_BYTE }.pack("C*")
          JSON.parse(bytes.force_encoding(Encoding::UTF_8))
        end

        def write_stable(filename, document)
          path = File.join(@directory, filename)
          File.write(path, "#{CanonicalJSON.dump(document)}\n", encoding: Encoding::UTF_8)
          File.chmod(0o600, path)
        end

        def read_json(filename)
          path = File.join(@directory, filename)
          raise ExecutionError, "memory store missing #{filename}" unless File.file?(path)

          text = File.read(path, encoding: Encoding::UTF_8)
          DuplicateKeyDetector.validate!(text)
          JSON.parse(text)
        end
      end
    end
  end
end

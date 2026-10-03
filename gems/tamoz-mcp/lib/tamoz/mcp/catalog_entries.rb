# frozen_string_literal: true

module Tamoz
  module Mcp
    # Admits and fingerprints the server-supplied capability definitions.
    class CatalogEntries
      def tool_entries(client, config)
        tools = client.tools
        seen = {}
        tools.map do |tool|
          name = validate_entry_name!(tool.name)
          record_unique_entry_name!(name, seen)

          description = bounded_description(tool.description, config)
          schema = canonicalize_schema(name, tool.input_schema)
          annotations = canonicalize_annotations(tool.annotations)
          build_entry(name, :tool, description, schema, annotations)
        end
      end

      def canonicalize_schema(name, schema)
        canonicalize(validated_schema_candidate(name, schema))
      end

      def validated_schema_candidate(name, schema)
        candidate = schema.nil? ? {} : schema
        unless candidate.is_a?(Hash)
          raise ValidationError,
                "The MCP server entry #{name.inspect} has an invalid input schema."
        end

        begin
          MCP::Tool::InputSchema.new(candidate)
        rescue StandardError
          # Fail closed: an entry that fails schema validation fails the
          # whole snapshot (v1 simplification of the §5 quarantine rule).
          raise ValidationError,
                "The MCP server entry #{name.inspect} has an invalid input schema."
        end

        candidate
      end

      def resource_entries(client, config)
        client.resources.map do |resource|
          name = validate_entry_name!(resource['name'] || resource['uri'])
          description = bounded_description(resource['description'], config)
          schema = canonicalize(
            'uri' => resource['uri'].to_s, 'mimeType' => resource['mimeType'].to_s
          )
          build_entry(name, :resource, description, schema, nil)
        end
      end

      def prompt_entries(client, config)
        client.prompts.map do |prompt|
          name = validate_entry_name!(prompt['name'])
          description = bounded_description(prompt['description'], config)
          schema = canonicalize('arguments' => prompt['arguments'] || [])
          build_entry(name, :prompt, description, schema, nil)
        end
      end

      def validate_entry_name!(value)
        unless value.is_a?(String) && TOOL_NAME_PATTERN.match?(value)
          raise ValidationError, 'The MCP server lists an entry with an invalid name.'
        end

        value.dup.freeze
      end

      def record_unique_entry_name!(name, seen)
        raise ValidationError, "The MCP server lists a duplicate entry name #{name.inspect}." if seen.key?(name)

        seen[name] = true
      end

      def bounded_description(value, config)
        BoundedText.bound(value, config.budgets.max_description_bytes)
      end

      def canonicalize(object)
        CanonicalJSON.deep_freeze(CanonicalJSON.normalize(object))
      end

      def canonicalize_annotations(annotations)
        return nil if annotations.nil?

        canonicalize(annotations)
      end

      def build_entry(name, kind, description, schema, annotations)
        definition_digest = digest_entry(name, kind, description, schema, annotations)
        Entry.new(
          name: name,
          kind: kind,
          description: description,
          schema: schema,
          annotations: annotations,
          definition_digest: definition_digest
        ).freeze
      end

      def digest_entry(name, kind, description, schema, annotations)
        payload = ENTRY_DIGEST_DOMAIN + CanonicalJSON.dump(
          'name' => name,
          'kind' => kind.to_s,
          'description' => description,
          'schema' => schema,
          'annotations' => annotations
        )
        "sha256:#{Digest::SHA256.hexdigest(payload)}"
      end
    end
    private_constant :CatalogEntries
  end
end

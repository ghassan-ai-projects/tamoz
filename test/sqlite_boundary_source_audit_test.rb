# frozen_string_literal: true

require_relative "test_helper"
require_relative "../gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_source_audit"

class SQLiteBoundarySourceAuditTest < Minitest::Test
  SOURCE_PATHS = %w[
    checkpoint_store.rb
    lease_operations.rb
  ].map do |name|
    ROOT.join("gems", "tamoz-sqlite", "lib", "tamoz", "sqlite", name).to_s
  end.freeze

  def test_real_capability_sources_exactly_match_the_registry
    result = source_audit.audit!(
      registry: boundary_registry,
      paths: SOURCE_PATHS
    )

    assert result.frozen?
    assert_equal 18, result.length
    assert_equal 91, result.values.sum(&:length)
    assert_equal(
      {
        "checkpoint.commit.consume.{index}" => "write",
        "checkpoint.commit.advance" => "write",
        "checkpoint.commit.base" => "read"
      },
      result.fetch("checkpoint.commit").slice(
        "checkpoint.commit.consume.{index}",
        "checkpoint.commit.advance",
        "checkpoint.commit.base"
      )
    )
    assert_equal(
      "read",
      result.fetch("lease.validate").fetch("lease.validate.thread")
    )
  end

  def test_helper_label_expansion_is_resolved_by_call_site
    source = <<~RUBY
      def subject
        transaction(operation: "lease.acquire") do |tx|
          helper(tx, label: "lease.acquire")
        end
      end

      def helper(tx, label:)
        tx.first("\#{label}.row", "SELECT 1")
      end
    RUBY
    result = audit_fixture(
      source,
      registry_for(
        "lease.acquire" => {"lease.acquire.row" => "read"}
      )
    )

    assert_equal(
      {"lease.acquire" => {"lease.acquire.row" => "read"}},
      result
    )

    keyword_source = source
                     .sub("helper(tx, label:", "helper(tx: tx, label:")
                     .sub("def helper(tx, label:)", "def helper(tx:, label:)")
    assert_equal(
      result,
      audit_fixture(
        keyword_source,
        registry_for(
          "lease.acquire" => {"lease.acquire.row" => "read"}
        )
      )
    )
  end

  def test_only_reviewed_index_templates_are_accepted
    accepted = <<~RUBY
      def subject
        transaction(operation: "checkpoint.commit") do |tx|
          [0].each do |index|
            tx.execute("checkpoint.commit.consume.\#{index}", "DELETE")
          end
        end
      end
    RUBY
    result = audit_fixture(
      accepted,
      registry_for(
        "checkpoint.commit" => {
          "checkpoint.commit.consume.{index}" => "write"
        }
      )
    )
    assert_equal(
      "write",
      result.fetch("checkpoint.commit")
            .fetch("checkpoint.commit.consume.{index}")
    )

    rejected = accepted.sub(
      "checkpoint.commit.consume.",
      "checkpoint.commit.unreviewed."
    )
    error = assert_raises(Tamoz::ConfigurationError) do
      audit_fixture(
        rejected,
        registry_for(
          "checkpoint.commit" => {
            "checkpoint.commit.unreviewed.{index}" => "write"
          }
        )
      )
    end
    assert_match(/unreviewed SQLite statement label interpolation/, error.message)
  end

  def test_source_and_registry_omissions_fail_in_both_directions
    source = <<~RUBY
      transaction(operation: "lease.acquire") do |tx|
        tx.execute("lease.acquire.update", "UPDATE")
      end
    RUBY

    source_only = assert_raises(Tamoz::ConfigurationError) do
      audit_fixture(
        source,
        registry_for(
          "lease.acquire" => {"lease.acquire.other" => "write"}
        )
      )
    end
    assert_match(/absent from registry: lease\.acquire\.update/, source_only.message)
    assert_match(/absent from source: lease\.acquire\.other/, source_only.message)

    registry_only = assert_raises(Tamoz::ConfigurationError) do
      audit_fixture(
        source,
        registry_for(
          "lease.acquire" => {
            "lease.acquire.update" => "write",
            "lease.acquire.unreachable" => "read"
          }
        )
      )
    end
    assert_match(
      /absent from source: lease\.acquire\.unreachable/,
      registry_only.message
    )
  end

  def test_unreachable_transaction_helpers_are_rejected
    source = <<~RUBY
      transaction(operation: "lease.acquire") do |tx|
        tx.execute("lease.acquire.update", "UPDATE")
      end

      def hidden(tx)
        tx.first("lease.acquire.hidden", "SELECT 1")
      end
    RUBY

    error = assert_raises(Tamoz::ConfigurationError) do
      audit_fixture(
        source,
        registry_for(
          "lease.acquire" => {"lease.acquire.update" => "write"}
        )
      )
    end
    assert_match(/boundary helpers are unreachable: hidden/, error.message)
  end

  def test_direct_database_execute_and_filesystem_mutation_are_rejected
    valid_operation = <<~RUBY
      transaction(operation: "lease.acquire") do |tx|
        tx.execute("lease.acquire.update", "UPDATE")
      end
    RUBY
    registry = registry_for(
      "lease.acquire" => {"lease.acquire.update" => "write"}
    )
    treatments = {
      "SQLite3::Database.new(\"tamoz.db\")" => /direct SQLite3::Database/,
      "database_class = SQLite3::Database" => /direct SQLite3::Database/,
      "connection.execute(\"DELETE\")" => /direct execute outside Transaction/,
      "File.write \"tamoz.db\", \"bytes\"" => /filesystem mutation File.write/,
      "path = Pathname.new(\"tamoz.db\")" => /filesystem constant Pathname/,
      "public_send(method_name, \"DELETE\")" => /dynamic dispatch/,
      "eval(\"connection.execute('DELETE')\")" => /dynamic execution eval/
    }

    treatments.each do |treatment, message|
      error = assert_raises(Tamoz::ConfigurationError) do
        audit_fixture("#{valid_operation}\n#{treatment}\n", registry)
      end
      assert_match message, error.message
    end
  end

  def test_operation_without_block_and_invalid_source_fail_closed
    registry = registry_for(
      "lease.acquire" => {"lease.acquire.update" => "write"}
    )
    without_block = <<~RUBY
      transaction(operation: "lease.acquire")
    RUBY
    error = assert_raises(Tamoz::ConfigurationError) do
      audit_fixture(without_block, registry)
    end
    assert_match(/boundary operation requires a block/, error.message)

    missing_literal = assert_raises(Tamoz::ConfigurationError) do
      audit_fixture(
        "transaction do |tx|; tx.execute(\"lease.acquire.update\", \"UPDATE\"); end",
        registry
      )
    end
    assert_match(/must declare an operation literal/, missing_literal.message)

    dynamic_literal = assert_raises(Tamoz::ConfigurationError) do
      audit_fixture(
        "transaction(operation: operation_name) do |tx|; " \
        "tx.execute(\"lease.acquire.update\", \"UPDATE\"); end",
        registry
      )
    end
    assert_match(/must be a String literal/, dynamic_literal.message)

    syntax_error = assert_raises(Tamoz::ConfigurationError) do
      audit_fixture("def broken(", registry)
    end
    assert_match(/invalid Ruby syntax/, syntax_error.message)
  end

  private

  def audit_fixture(source, registry)
    Dir.mktmpdir("tamoz-boundary-source") do |directory|
      path = File.join(directory, "capability.rb")
      File.write(path, source, encoding: Encoding::UTF_8)
      return source_audit.audit!(registry:, paths: [path])
    end
  end

  def registry_for(operations)
    document = {
      "registry_version" => 1,
      "operations" => operations.map do |operation, statements|
        {
          "operation" => operation,
          "phase" => 2,
          "kill_required" => true,
          "statements" => statements.map do |template, access|
            {
              "template" => template,
              "access" => access,
              "max_instances" => 1
            }
          end
        }
      end
    }
    Struct.new(:document).new(document)
  end

  def source_audit
    Tamoz::SQLite.const_get(:BoundarySourceAudit, false)
  end

  def boundary_registry
    Tamoz::SQLite.const_get(:BoundaryRegistry, false)
  end
end

# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class SQLiteArtifactStoreTest < Minitest::Test
  def with_store
    Dir.mktmpdir do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      yield adapter.bind_artifact_store(tenant: 'profile:ops')
    ensure
      adapter&.close
    end
  end

  def test_binary_bytes_round_trip_exactly
    with_store do |store|
      bytes = "%PDF-1.4\n\x00\xFF\xFE\x80binary".b
      digest = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
      store.retain(digest:, bytes:, media_type: 'application/pdf')

      assert_equal bytes, store.resolve(digest).fetch('bytes').b
    end
  end

  def test_a_tampered_row_is_refused_on_resolve
    Dir.mktmpdir do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      store = adapter.bind_artifact_store(tenant: 'profile:ops')
      digest = "sha256:#{Digest::SHA256.hexdigest('original')}"
      store.retain(digest:, bytes: 'original')
      adapter.__send__(:transaction, operation: 'test.tamper') do |tx|
        tx.execute('test.tamper', 'UPDATE tamoz_artifacts SET bytes = ? WHERE digest = ?', ['tampered', digest])
      end

      assert_raises(Tamoz::SQLite::ArtifactStore::ArtifactStoreError) { store.resolve(digest) }
    ensure
      adapter&.close
    end
  end

  def test_another_tenant_cannot_resolve_the_bytes
    Dir.mktmpdir do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      digest = "sha256:#{Digest::SHA256.hexdigest('x')}"
      adapter.bind_artifact_store(tenant: 'profile:ops').retain(digest:, bytes: 'x')

      assert_nil adapter.bind_artifact_store(tenant: 'profile:other').resolve(digest)
    ensure
      adapter&.close
    end
  end
end

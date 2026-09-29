# frozen_string_literal: true

require 'digest'
require 'json'

# Reads a run back from what the request bytes, the effect journal and the durable state recorded, never from the
# agent's narration.
module SubagentInspection
  def wire_names(bytes) = JSON.parse(bytes).fetch('tools').map { |tool| tool.dig('function', 'name') }

  def tool_messages(bytes)
    JSON.parse(bytes).fetch('messages').select { |message| message['role'] == 'tool' }
                                       .map { |message| message.fetch('content') }
  end

  def header_digests(bytes)
    request = JSON.parse(bytes)
    [Digest::SHA256.hexdigest(Tamoz::Core.jcs(request.fetch('tools'))),
     Digest::SHA256.hexdigest(request.fetch('messages').first.fetch('content'))]
  end

  def messages_bytes(bytes) = JSON.generate(JSON.parse(bytes).fetch('messages')).bytesize

  def delegation_results(model)
    tool_messages(model.parent_requests.last).select { |text| text.start_with?('Subagent') }
  end

  def trace_events(outcome, name) = outcome.state.fetch(:work_trace).select { |event| event['event'] == name }

  def tree_digest(root)
    files = Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort
    pairs = files.map { |path| [path.delete_prefix("#{root}/"), Digest::SHA256.file(path).hexdigest] }
    Digest::SHA256.hexdigest(JSON.generate(pairs))
  end

  def journal(adapter)
    rows = nil
    adapter.store.open_transaction(label: 'spec.journal') do |tx|
      rows = tx.rows('spec.journal', 'SELECT namespace, execution_id, operation, status FROM tamoz_effects ' \
                                     'ORDER BY created_at_ms, effect_key', [])
    end
    rows.map { |namespace, execution_id, operation, status| { namespace:, execution_id:, operation:, status: } }
  end

  def child_journal(adapter) = journal(adapter).select { |row| row.fetch(:namespace).include?('subgraph') }

  def entry_texts(adapter, entries)
    store = adapter.bind_artifact_store(tenant: 'work-test')
    entries.map { |entry| [entry, entry['text_ref'] ? store.resolve(entry['text_ref']).fetch('bytes') : ''] }
  end
end

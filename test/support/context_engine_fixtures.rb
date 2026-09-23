# frozen_string_literal: true

module ContextEngineFixtures
  CE = Tamoz::ContextEngine

  def sections
    [
      CE::Section.new(name: 'identity', order: 100, text: 'You are Tamoz.'),
      CE::Section.new(name: 'tools', order: 300, text: 'Use the tools.'),
      CE::Section.new(name: 'operating', order: 200, text: 'Plan first.')
    ]
  end

  def tools
    [
      CE::ToolSchema.new(name: 'read_file', description: 'Read a file.',
                         parameters: { 'type' => 'object', 'properties' => { 'path' => { 'type' => 'string' } } }),
      CE::ToolSchema.new(name: 'apply_patch', description: 'Patch a file.',
                         parameters: { 'type' => 'object', 'properties' => { 'path' => { 'type' => 'string' } } })
    ]
  end

  def unicode_header(sections_list = sections, tools_list = tools)
    extra = CE::Section.new(name: 'résumé', order: 150, text: 'Réponds en français — ça va?')
    tool = CE::ToolSchema.new(name: 'Zeta', description: 'Ünïcode tool.', parameters: { 'type' => 'object' })
    CE::RequestHeader.build(sections: sections_list + [extra], tools: tools_list + [tool], model: 'deepseek-chat')
  end

  def header(model: 'deepseek-chat') = CE::RequestHeader.build(sections:, tools:, model:)

  def store = @store ||= CE::MemoryStore.new

  def resolve = CE::Surface.resolver(store)

  def append(entries, kind, text, **fields)
    entries + [CE::Surface.entry(kind:, seq: CE::Surface.next_seq(entries), text:, store:, **fields)]
  end

  def tool_round(entries, id, name, arguments, result)
    call = { 'id' => id, 'name' => name, 'arguments' => JSON.generate(arguments) }
    entries = append(entries, 'assistant', '', tool_calls: [call])
    append(entries, 'tool_result', result, tool_call_id: id, name:)
  end

  def scripted_turn(steps, result_bytes: 200)
    entries = append([], 'runtime', 'workspace: /tmp/w', pinned: true)
    entries = append(entries, 'user', 'Task: fix the bug. Never change the public signature of Foo#bar.', pinned: true)
    steps.times do |index|
      entries = tool_round(entries, "call_#{index}", 'read_file', { 'path' => "lib/f#{index}.rb" },
                           "line #{index}\n" * (result_bytes / 7))
    end
    entries
  end
end

module ContextEngineFixtures
  def compacted(entries, retain_tokens: 700)
    selection = CE::Compaction.select(entries, retain_tokens:, resolve:)
    summary = CE::Compaction::SECTIONS.map { |section| "## #{section}\n- (none)" }.join("\n")
    entries + [CE::Compaction.checkpoint_entry(summary, selection:, entries:, store:)]
  end

  def pruned(entries, before_seq)
    budget = CE::Pruner::Budget.new(threshold_chars: 2048, head_chars: 512, tail_chars: 256)
    entries + CE::Pruner.prune(entries, store:, resolve:, before_seq:, budget:).map(&:entry)
  end

  REPLACEMENT_SOURCES = %w[prune compaction].freeze

  def replacement_added?(before, after)
    (after - before).any? { |entry| entry.key?('replaces') && REPLACEMENT_SOURCES.include?(entry['source']) }
  end
end

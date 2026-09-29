# frozen_string_literal: true

require 'tamoz/core'
require_relative 'research/version'
require_relative 'research/error'
require_relative 'research/text'
require_relative 'research/budgets'
require_relative 'research/brief'
require_relative 'research/wave'
require_relative 'research/web'
require_relative 'research/sources'
require_relative 'research/ledger'
require_relative 'research/report'
require_relative 'research/run_folder'

module Tamoz
  # The rules of a deep-research run, and the only way into them. Pure: no I/O, no model or network call. A method
  # given model or user input raises Tamoz::Research::Error when it does not hold; restore_* take Tamoz's own records.
  #
  #   Tamoz::Research.plan_text(Tamoz::Research.brief(arguments, budgets:), budgets:) # => "Here is my research plan…"
  module Research
    private_constant :Text, :Budgets, :Brief, :Wave, :Web, :Sources, :Ledger, :Report, :RunFolder

    module_function

    # The shipped budgets, or a copy `override` narrows (it may only lower numbers).
    def budgets(override: nil)
      shipped = Budgets.shipped
      override ? shipped.narrowed(override) : shipped
    end

    # A research plan from propose_research_plan's arguments.
    def brief(arguments, budgets:) = Brief.parse(arguments, budgets:)

    def restore_brief(document) = Brief.from_h(document)

    def plan_text(brief, budgets:) = brief.render(minutes: budgets.depth(brief.depth).minutes)

    # A wave from research_wave's arguments, checked against what the ledger says is open and spent.
    def wave(arguments, ledger:, budgets:)
      Wave.parse(arguments, ledger:, depth: budgets.depth(ledger.brief.depth), budgets:)
    end

    def search_hits(json, ordinal:) = Web.hits(json, ordinal:)

    def render_hits(hits, ordinal:) = Web.render_hits(hits, ordinal:)

    def page(json, ref:) = Web.page(json, ref:)

    def render_page(page) = Web.render_page(page)

    # A child's report_sources, accepted only when every excerpt is in a page it read (`pages`: {ref => page}).
    def sources(arguments, pages:, assigned:) = Sources.parse(arguments, pages:, assigned:)

    def restore_sources(document) = Sources.from_h(document)

    # `children`: [{'wave', 'sub_questions', 'sources' (a Sources#to_h or nil), 'searches', 'page_reads'}].
    def ledger(brief:, children:)
      Ledger.new(brief:, children: children.map do |child|
        found = child['sources']
        Ledger::Child.new(wave: child.fetch('wave'), sub_question_ids: child.fetch('sub_questions'),
                          searches: child.fetch('searches'), page_reads: child.fetch('page_reads'),
                          sources: found && Sources.from_h(found))
      end)
    end

    def stop_reason(ledger, budgets:) = ledger.stop_reason(depth: budgets.depth(ledger.brief.depth), budgets:)

    # [[sentence, [claim ids]]] for every sentence of `body` that cites a claim.
    def citations(body) = Report.citations(body)

    # :reek:LongParameterList
    def report(arguments, ledger:, stop_reason:, unsupported: [])
      Report.parse(arguments, ledger:, stop_reason:, unsupported:)
    end

    # :reek:LongParameterList
    def run_record(ledger:, report:, stop_reason:, extra: {})
      brief = ledger.brief
      { 'question' => brief.question, 'depth' => brief.depth, 'sub_questions' => brief.ids.length,
        'statuses' => ledger.statuses, 'stop_reason' => stop_reason, 'claims' => ledger.claims.length,
        'sources' => ledger.sources.length, 'cited_claims' => report.cited.length,
        'gaps' => report.gap_count }.merge(ledger.used).merge(extra)
    end

    def run_folder_name(date:, question:, run_id:) = RunFolder.name(date:, question:, run_id:)

    def run_folder_files(ledger:, report:, record:) = RunFolder.files(ledger:, report:, record:)
  end
end

# frozen_string_literal: true

module Tamoz
  module Research
    # A research child's report_sources, accepted only when every excerpt occurs in a page that child read.
    # :reek:ControlParameter :reek:FeatureEnvy :reek:LongParameterList :reek:NestedIterators :reek:TooManyStatements
    # :reek:UncommunicativeVariableName
    # -- a checker that collects every problem in one pass, so the child can fix them all at once.
    class Sources
      STATUSES = %w[found conflicting not_found].freeze
      EXCERPT = (20..400)
      MAX_CLAIMS = 12

      # One accepted claim: what it says, the excerpt that backs it, and the page it quotes.
      Claim = Data.define(:text, :excerpt, :primary, :url, :title, :published)
      # A sub-question as one child reports it: found, conflicting or not_found, with its claims.
      Finding = Data.define(:sub_question, :status, :claims, :note)

      attr_reader :summary, :findings

      # `pages`: {ref => Web::Page} this child read; `assigned`: its sub-question ids.
      def self.parse(arguments, pages:, assigned:)
        raise Error, 'report_sources takes an object' unless arguments.is_a?(Hash)

        problems = []
        findings = findings(arguments['findings'], pages, assigned, problems)
        missing = assigned - findings.map(&:sub_question)
        problems << "report every assigned sub-question; missing #{missing.join(', ')}" unless missing.empty?
        raise Error, "Sources not accepted:\n- #{problems.join("\n- ")}" unless problems.empty?

        new(summary: Text.bounded(arguments['summary'], 'summary', max: 1500), findings:)
      end

      def self.findings(items, pages, assigned, problems)
        raise Error, 'findings must be a list' unless items.is_a?(Array)

        items.filter_map do |item|
          next note(problems, 'each finding must be an object') unless item.is_a?(Hash)

          finding(item, pages, assigned, problems)
        end
      end

      def self.finding(item, pages, assigned, problems)
        id = item['sub_question']
        return note(problems, "#{id.inspect} is not one of your sub-questions") unless assigned.include?(id)

        status = item['status']
        return note(problems, "#{id}: status must be one of #{STATUSES.join(', ')}") unless STATUSES.include?(status)

        build_finding(item, id, status, pages, problems)
      end

      def self.build_finding(item, id, status, pages, problems)
        raw_claims = Array(item['claims'])
        note(problems, "#{id}: at most #{MAX_CLAIMS} claims per sub-question") if raw_claims.length > MAX_CLAIMS
        claims = raw_claims.first(MAX_CLAIMS).filter_map { |raw| claim(raw, id, pages, problems) }
        problem = shape_problem(id, status, claims)
        note(problems, problem) if problem
        Finding.new(sub_question: id, status:, claims: claims.freeze, note: Text.squash(item['note']))
      end

      def self.shape_problem(id, status, claims)
        none = claims.empty?
        case status
        when 'found' then "#{id}: found needs at least one claim" if none
        when 'conflicting' then "#{id}: conflicting needs the claims on each side (2 or more)" if claims.length < 2
        else "#{id}: not_found must carry no claims" unless none
        end
      end

      def self.claim(raw, id, pages, problems)
        return note(problems, "#{id}: each claim must be an object") unless raw.is_a?(Hash)

        ref = raw['page']
        page = pages[ref]
        return note(problems, "#{id}: page #{ref.inspect} is not a page you read") unless page

        excerpt = quoted(page, raw['excerpt'], id)
        Claim.new(text: Text.bounded(raw['claim'], "#{id} claim", max: 400), excerpt:, primary: raw['primary'] == true,
                  url: page.url, title: page.title, published: page.published)
      rescue Error => e
        note(problems, e.message)
      end

      def self.quoted(page, raw, id)
        excerpt = Text.squash(raw)
        raise Error, "#{id}: an excerpt must be #{EXCERPT.min}-#{EXCERPT.max} characters" unless
          EXCERPT.cover?(excerpt.length)
        raise Error, "#{id}: the excerpt is not in #{page.ref}; quote the page exactly" unless
          Text.contains?(page.text, excerpt)

        excerpt
      end

      def self.note(problems, message)
        problems << message
        nil
      end

      private_class_method :findings, :finding, :build_finding, :shape_problem, :claim, :quoted, :note

      def initialize(summary:, findings:)
        @summary = summary
        @findings = findings.freeze
        freeze
      end

      def to_h
        { 'summary' => @summary,
          'findings' => @findings.map do |finding|
            { 'sub_question' => finding.sub_question, 'status' => finding.status, 'note' => finding.note,
              'claims' => finding.claims.map { |claim| claim.to_h.transform_keys(&:to_s) } }
          end }
      end

      def self.from_h(document)
        new(summary: document.fetch('summary'),
            findings: document.fetch('findings').map do |finding|
              Finding.new(sub_question: finding.fetch('sub_question'), status: finding.fetch('status'),
                          note: finding.fetch('note'),
                          claims: finding.fetch('claims').map do |claim|
                            Claim.new(**claim.transform_keys(&:to_sym))
                          end.freeze)
            end)
      end

      # What the lead reads back: one line per claim, never the pages.
      def render
        lines = [@summary]
        @findings.each do |finding|
          note = finding.note
          lines << "#{finding.sub_question} #{finding.status}#{" — #{note}" unless note.empty?}"
          lines.concat(finding.claims.map { |claim| "  - #{claim.text} (#{Text.host(claim.url)})" })
        end
        lines.join("\n")
      end
    end
  end
end

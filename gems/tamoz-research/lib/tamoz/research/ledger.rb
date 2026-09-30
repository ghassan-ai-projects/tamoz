# frozen_string_literal: true

module Tamoz
  module Research
    # Everything a run's children found, merged: numbered claims (C1…), their sources, each sub-question's status,
    # what the run has spent, and whether it may stop.
    # :reek:FeatureEnvy :reek:NestedIterators :reek:TooManyStatements :reek:UtilityFunction :reek:ControlParameter
    # :reek:TooManyMethods :reek:DuplicateMethodCall -- it reads the children's values to merge them.
    class Ledger
      # One finished child: its wave, its assignment, its accepted Sources (nil when it produced none) and its spend.
      Child = Data.define(:wave, :sub_question_ids, :sources, :searches, :page_reads)
      # A numbered claim (C1…) with the sub-question it answers, the wave of the child that found it, and the page it
      # quotes.
      Entry = Data.define(:id, :sub_question, :wave, :text, :excerpt, :primary, :source)
      # A page a claim quotes.
      Source = Data.define(:url, :title, :published)

      # A child must have searched this much before its not_found makes a sub-question unanswerable.
      MIN_SEARCHES_FOR_NOT_FOUND = 3

      attr_reader :brief, :children, :claims

      def initialize(brief:, children:)
        @brief = brief
        @children = children.freeze
        @claims = numbered_claims.freeze
        freeze
      end

      def sources = @claims.map(&:source).uniq(&:url)

      def claim(id) = @claims.find { |entry| entry.id == id }

      def statuses = @brief.ids.to_h { |id| [id, status(id, @children)] }

      def open_ids = statuses.select { |_, status| status == 'open' }.keys

      def used
        { 'children' => @children.length, 'waves' => @children.map(&:wave).max || 0,
          'searches' => @children.sum(&:searches), 'page_reads' => @children.sum(&:page_reads) }
      end

      # Why the run may end now, or nil while it must keep going.
      def stop_reason(depth:, budgets:)
        return 'coverage' if open_ids.empty?
        return 'budget' if spent?(depth, budgets)

        'saturation' if saturated?
      end

      # What the lead reads after a wave: each sub-question's status and the claims behind it.
      def render
        statuses.map do |id, state|
          lines = ["#{id} #{state}: #{@brief.fetch(id).text}"]
          lines + @claims.select { |entry| entry.sub_question == id }.map do |entry|
            "  #{entry.id} #{entry.text} (#{Text.host(entry.source.url)}#{', primary' if entry.primary})"
          end
        end.flatten.join("\n")
      end

      private

      def numbered_claims
        claim_pairs.each_with_index.map do |(child, sub_question, claim), index|
          Entry.new(id: "C#{index + 1}", sub_question:, wave: child.wave, text: claim.text, excerpt: claim.excerpt,
                    primary: claim.primary,
                    source: Source.new(url: claim.url, title: claim.title, published: claim.published))
        end
      end

      # [child, sub-question id, claim] for every accepted claim, once each: the child that found a claim is what
      # tells one wave's work from another's.
      def claim_pairs
        pairs = @children.flat_map do |child|
          findings([child]).flat_map do |finding|
            finding.claims.map { |claim| [child, finding.sub_question, claim] }
          end
        end
        pairs.uniq { |_child, sub_question, claim| [sub_question, claim.url, claim.excerpt] }
      end

      def findings(children) = children.filter_map(&:sources).flat_map(&:findings)

      def status(id, children)
        mine = findings(children).select { |finding| finding.sub_question == id }
        reported = mine.map(&:status)
        claims = mine.flat_map(&:claims)
        return 'contested' if reported.include?('conflicting')
        return 'answered' if settled?(claims)

        claims.empty? && searched_out?(id, children) ? 'unanswerable' : 'open'
      end

      def searched_out?(id, children)
        children.any? do |child|
          child.searches >= MIN_SEARCHES_FOR_NOT_FOUND && child.sources&.findings&.any? do |finding|
            finding.sub_question == id && finding.status == 'not_found'
          end
        end
      end

      def settled?(claims) = claims.any?(&:primary) || claims.map { |claim| Text.host(claim.url) }.uniq.length >= 2

      def spent?(depth, budgets)
        spend = used
        spend.fetch('waves') >= depth.waves || spend.fetch('searches') >= depth.searches ||
          spend.fetch('page_reads') >= depth.page_reads ||
          spend.fetch('children') >= budgets.ceilings.fetch('children_per_run')
      end

      # The last wave added no claim to any sub-question that was open before it.
      def saturated?
        last = used.fetch('waves')
        return false if last.zero?

        were_open = open_before(last)
        findings(@children.select { |child| child.wave == last })
          .none? { |finding| were_open.include?(finding.sub_question) && !finding.claims.empty? }
      end

      def open_before(wave)
        earlier = @children.select { |child| child.wave < wave }
        @brief.ids.select { |id| status(id, earlier) == 'open' }
      end
    end
  end
end

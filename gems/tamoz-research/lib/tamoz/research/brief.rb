# frozen_string_literal: true

module Tamoz
  module Research
    # The research plan the lead proposes and the user accepts: the question, its sub-questions (each seen from a
    # perspective), what is left out, and how deep to go.
    # :reek:TooManyInstanceVariables :reek:TooManyStatements :reek:NilCheck -- one checked plan and its rendering.
    class Brief
      MAX_SUB_QUESTIONS = 8
      MAX_LEFT_OUT = 6

      # One sub-question: its id (Q1…), what it asks, and the perspective it is researched from.
      SubQuestion = Data.define(:id, :text, :perspective)

      attr_reader :question, :sub_questions, :left_out, :depth, :clarifying_question

      # `arguments` are propose_research_plan's; sub-question ids are assigned here, Q1 onward.
      def self.parse(arguments, budgets:)
        raise Error, 'the plan must be an object' unless arguments.is_a?(Hash)

        new(question: Text.bounded(arguments['question'], 'question', max: 600),
            sub_questions: sub_questions(arguments['sub_questions']),
            left_out: left_out(arguments.fetch('left_out', [])),
            depth: budgets.depth(arguments['depth']).name,
            clarifying_question: clarifying(arguments['clarifying_question']))
      end

      def self.sub_questions(items)
        raise Error, "sub_questions must list 1 to #{MAX_SUB_QUESTIONS} items" unless
          items.is_a?(Array) && items.length.between?(1, MAX_SUB_QUESTIONS)

        parsed = items.each_with_index.map { |item, index| sub_question(item, "Q#{index + 1}") }
        texts = parsed.map { |sub| sub.text.downcase }
        raise Error, 'two sub-questions have the same text' unless texts.uniq.length == texts.length

        parsed.freeze
      end

      def self.sub_question(item, id)
        raise Error, 'each sub-question must be an object with text and perspective' unless item.is_a?(Hash)

        SubQuestion.new(id:, text: Text.bounded(item['text'], 'sub-question text', max: 300),
                        perspective: Text.bounded(item['perspective'], 'perspective', max: 120))
      end

      def self.left_out(items)
        raise Error, "left_out must list at most #{MAX_LEFT_OUT} items" unless
          items.is_a?(Array) && items.length <= MAX_LEFT_OUT

        items.map { |item| Text.bounded(item, 'left_out item', max: 200) }.freeze
      end

      def self.clarifying(value)
        if value.nil? || value == ''
          nil
        else
          Text.bounded(value, 'clarifying_question',
                       max: 300)
        end
      end

      private_class_method :sub_questions, :sub_question, :left_out, :clarifying

      def initialize(question:, sub_questions:, left_out:, depth:, clarifying_question:)
        @question = question
        @sub_questions = sub_questions
        @left_out = left_out
        @depth = depth
        @clarifying_question = clarifying_question
        freeze
      end

      def ids = @sub_questions.map(&:id)

      def fetch(id) = @sub_questions.find { |sub| sub.id == id } || raise(Error, "unknown sub-question #{id.inspect}")

      def to_h
        { 'question' => @question, 'sub_questions' => @sub_questions.map { |sub| sub.to_h.transform_keys(&:to_s) },
          'left_out' => @left_out, 'depth' => @depth, 'clarifying_question' => @clarifying_question }
      end

      def self.from_h(document)
        new(question: document.fetch('question'), left_out: document.fetch('left_out').dup.freeze,
            depth: document.fetch('depth'), clarifying_question: document['clarifying_question'],
            sub_questions: document.fetch('sub_questions').map do |sub|
              SubQuestion.new(id: sub.fetch('id'), text: sub.fetch('text'), perspective: sub.fetch('perspective'))
            end.freeze)
      end

      # The plan as the user reads it, in plain words.
      def render(minutes:)
        lines = ['Here is my research plan.', '', "Question: #{@question}", '', 'I will look into:']
        lines += @sub_questions.each_with_index.map do |sub, index|
          "#{index + 1}. #{sub.text} (seen as #{sub.perspective})"
        end
        lines += ['', "Leaving out: #{@left_out.join('; ')}"] unless @left_out.empty?
        lines += ['', "Depth: #{@depth}, about #{minutes} minutes."]
        lines += ['', @clarifying_question] if @clarifying_question
        (lines + ['', 'Reply "go" to start, tell me what to change, or "stop".']).join("\n")
      end
    end
  end
end

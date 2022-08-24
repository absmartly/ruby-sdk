# frozen_string_literal: true
require_relative 'mock_evaluator'

RSpec.describe Absmartly::Jsonexpr::Operators::ValueOperator do
  context "evaluate" do
    let(:combinator) { Absmartly::Jsonexpr::Operators::ValueOperator.new }
    let!(:evaluator) { MockEvaluator.new }

    it "should not call evaluator evaluate" do
      expect(combinator.evaluate(evaluator, 0)).to eq 0
      expect(combinator.evaluate(evaluator, 1)).to eq 1
      expect(combinator.evaluate(evaluator, true)).to eq true
      expect(combinator.evaluate(evaluator, false)).to eq false
      expect(combinator.evaluate(evaluator, "")).to eq ""
      expect(combinator.evaluate(evaluator, nil)).to eq nil
      expect(combinator.evaluate(evaluator, ())).to eq ()
      expect(combinator.evaluate(evaluator, [])).to eq []
    end
  end
end

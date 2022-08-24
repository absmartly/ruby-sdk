# frozen_string_literal: true
require_relative 'mock_evaluator'

RSpec.describe Absmartly::Jsonexpr::Operators::NullOperator do
  context "evaluate" do
    let(:operator) { Absmartly::Jsonexpr::Operators::NullOperator.new }
    let!(:evaluator) { MockEvaluator.new }

    it "should return true if argument is null" do
      evaluator = double(:evaluator, evaluate: nil, boolean_convert: true)

      expect(operator.evaluate(evaluator, nil)).to eq true
      expect(evaluator).to have_received(:evaluate).once
      expect(evaluator).to have_received(:evaluate).with(nil)
      expect(evaluator).to have_received(:evaluate)
    end

    it "should return true if argument is not null" do
      evaluator = double(:evaluator, evaluate: [!nil, !nil], boolean_convert: true)

      expect(operator.evaluate(evaluator, true)).to eq false

      expect(evaluator).to have_received(:evaluate).once
      expect(evaluator).to have_received(:evaluate).with(true)

      expect(operator.evaluate(evaluator, false)).to eq false
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(false)

      expect(operator.evaluate(evaluator, 0)).to eq false
      expect(evaluator).to have_received(:evaluate).exactly(3).times
      expect(evaluator).to have_received(:evaluate).with(0)

    end

  end
end

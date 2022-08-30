# frozen_string_literal: true
require_relative 'mock_evaluator'

RSpec.describe Absmartly::Jsonexpr::Operators::NotOperator do
  context "evaluate" do
    let(:operator) { Absmartly::Jsonexpr::Operators::NotOperator.new }
    # let!(:evaluator) { MockEvaluator.new }

    it "should return true if argument is falsy" do
      evaluator = double(:evaluator, evaluate: false, boolean_convert: false)

      expect(operator.evaluate(evaluator, false)).to eq true
      expect(evaluator).to have_received(:evaluate).once
      expect(evaluator).to have_received(:evaluate).with(false)
      expect(evaluator).to have_received(:boolean_convert).once
    end
    it "should return false if argument is truthy" do
      evaluator = double(:evaluator, evaluate: true, boolean_convert: true)
      expect(operator.evaluate(evaluator, true)).to eq false

    end

    it "should return true if argument is null" do
      evaluator = double(:evaluator, evaluate: nil, boolean_convert: false)

      expect(operator.evaluate(evaluator, nil)).to eq true
      expect(evaluator).to have_received(:evaluate).once
      expect(evaluator).to have_received(:evaluate).with(nil)
      expect(evaluator).to have_received(:boolean_convert).once
      expect(evaluator).to have_received(:boolean_convert).with(nil)
      
    end

  end
end

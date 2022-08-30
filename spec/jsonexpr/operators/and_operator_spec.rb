# frozen_string_literal: true
require_relative 'mock_evaluator'

RSpec.describe Absmartly::Jsonexpr::Operators::AndOperator do
  context "evaluate" do
    let(:combinator) { Absmartly::Jsonexpr::Operators::AndOperator.new }
    # let!(:evaluator) { MockEvaluator.new }
    
    it "should return true if all arguments evaluate to true" do
      evaluator = double(:evaluator, evaluate: true, boolean_convert: true)
      expect(combinator.evaluate(evaluator, [true])).to eq true
      expect(evaluator).to have_received(:evaluate).once
      expect(evaluator).to have_received(:evaluate).with(true)
      expect(evaluator).to have_received(:boolean_convert).once
      expect(evaluator).to have_received(:boolean_convert).with(true)
    end
    
    it "should return true if all arguments evaluate to false" do
      evaluator = double(:evaluator, evaluate: false, boolean_convert: false)
      expect(combinator.evaluate(evaluator, [false])).to eq false
      expect(evaluator).to have_received(:evaluate).once
      expect(evaluator).to have_received(:evaluate).with(false)
      expect(evaluator).to have_received(:boolean_convert).once
      expect(evaluator).to have_received(:boolean_convert).with(false)
    end
    
    it "should return false if any argument evaluates to null" do
      evaluator = double(:evaluator, evaluate: nil, boolean_convert: false)
      expect(combinator.evaluate(evaluator, [nil])).to eq false
      expect(evaluator).to have_received(:evaluate).once
      expect(evaluator).to have_received(:evaluate).with(nil)
      expect(evaluator).to have_received(:boolean_convert).once
      expect(evaluator).to have_received(:boolean_convert).with(nil)
    end
    
    it "should short-circuit and not evaluate unnecessary expressions" do
      evaluator = double(:evaluator, evaluate: [true, false, true], boolean_convert: false)
      expect(combinator.evaluate(evaluator,[true, false, true] )).to eq false
      expect(combinator.evaluate(evaluator,[true, false, true] )).to eq false
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:boolean_convert).twice
      expect(evaluator).to have_received(:evaluate).with(true).twice
      expect(evaluator).to have_received(:boolean_convert).with([true, false, true]).twice
    end
    
    it "should combine multiple arguments" do
      evaluator = double(:evaluator, evaluate: [true, true], boolean_convert: true)
      expect(combinator.evaluate(evaluator,[true, true] )).to eq true
      expect(combinator.evaluate(evaluator,[true, true, true] )).to eq true
      evaluator = double(:evaluator, evaluate: [true, false], boolean_convert: false)
      expect(combinator.evaluate(evaluator,[true, false] )).to eq false
      expect(combinator.evaluate(evaluator,[false,true] )).to eq false
      expect(combinator.evaluate(evaluator,[false, false] )).to eq false
      expect(combinator.evaluate(evaluator,[false, false, false] )).to eq false
    end
  end
end

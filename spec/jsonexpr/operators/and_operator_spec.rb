# frozen_string_literal: true
require_relative 'mock_evaluator'

RSpec.describe Absmartly::Jsonexpr::Operators::AndOperator do
  context "evaluate" do
    let(:combinator) { Absmartly::Jsonexpr::Operators::AndOperator.new }
    let!(:evaluator) { MockEvaluator.new }
    
    it "should return true if all arguments evaluate to true" do
      expect(combinator.evaluate(evaluator, [true])).to eq true
    end
    
    it "should return true if all arguments evaluate to false" do
    end
    
    it "should return false if any argument evaluates to null" do
    end
    
    it "should short-circuit and not evaluate unnecessary expressions" do
    end
    
    it "should combine multiple arguments" do
    end
  end
end

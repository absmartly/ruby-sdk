# frozen_string_literal: true

require_relative "./shared_operator"
require "json_expr/operators/value_operator"

RSpec.describe ValueOperator do
  include_examples "shared operator"

  let(:operator) { described_class.new }
  describe ".evaluate" do
    it "test evaluate" do
      expect(operator.evaluate(evaluator,  0)).to eq(0)
      expect(operator.evaluate(evaluator,  1)).to eq(1)
      expect(operator.evaluate(evaluator,  true)).to eq(true)
      expect(operator.evaluate(evaluator,  false)).to eq(false)
      expect(operator.evaluate(evaluator,  "")).to eq("")
      expect(operator.evaluate(evaluator,  EMPTY_MAP)).to eq(EMPTY_MAP)
      expect(operator.evaluate(evaluator,  EMPTY_LIST)).to eq(EMPTY_LIST)
      expect(operator.evaluate(evaluator,  nil)).to be_nil
      expect(evaluator).to have_received(:evaluate).exactly(0).time
    end
  end
end

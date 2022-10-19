# frozen_string_literal: true

require_relative "./shared_operator"
require "json_expr/operators/greater_than_or_equal_operator"

RSpec.describe GreaterThanOrEqualOperator do
  include_examples "shared operator"

  let(:operator) { described_class.new }
  describe ".evaluate" do
    it "test evaluate" do
      expect(operator.evaluate(evaluator, [0, 0])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(0).twice
      expect(evaluator).to have_received(:compare).with(0, 0).once

      reset_evaluator
      expect(operator.evaluate(evaluator, [1, 0])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(0).once
      expect(evaluator).to have_received(:evaluate).with(1).once
      expect(evaluator).to have_received(:compare).with(1, 0).once

      reset_evaluator
      expect(operator.evaluate(evaluator, [0, 1])).to be_falsey
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(0).once
      expect(evaluator).to have_received(:evaluate).with(1).once
      expect(evaluator).to have_received(:compare).with(0, 1).once

      reset_evaluator
      expect(operator.evaluate(evaluator, [nil, nil])).to be_nil
      expect(evaluator).to have_received(:evaluate).once
      expect(evaluator).to have_received(:compare).exactly(0).time
    end
  end
end

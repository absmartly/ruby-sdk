# frozen_string_literal: true

require_relative "./shared_operator"
require "json_expr/operators/equals_operator"

RSpec.describe EqualsOperator do
  include_examples "shared operator"

  let(:operator) { described_class.new }
  describe ".evaluate" do
    it "test evaluate" do
      expect(operator.evaluate(evaluator, [0, 0])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(0).twice
      expect(evaluator).to have_received(:compare).with(0, 0).once

      reset_evaluator
      expect(operator.evaluate(evaluator, [1, 0])).to be_falsey
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

      reset_evaluator
      expect(operator.evaluate(evaluator, [[1, 2], [1, 2]])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:compare).once

      reset_evaluator
      expect(operator.evaluate(evaluator, [[1, 2], [2, 3]])).to be_nil
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:compare).once

      reset_evaluator
      expect(operator.evaluate(evaluator, [{ "a": 1, "b": 2 }, { "a": 1, "b": 2 }])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:compare).once

      reset_evaluator
      expect(operator.evaluate(evaluator, [{ "a": 1, "b": 2 }, { "a": 3, "b": 4 }])).to be_nil
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:compare).once
    end
  end
end

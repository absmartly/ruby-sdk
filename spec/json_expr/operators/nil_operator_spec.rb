# frozen_string_literal: true

require_relative "./shared_operator"
require "json_expr/operators/nil_operator"

RSpec.describe NilOperator do
  include_examples "shared operator"

  let(:operator) { described_class.new }
  describe ".evaluate" do
    it "test nil" do
      expect(operator.evaluate(evaluator, nil)).to be_truthy
      expect(evaluator).to have_received(:evaluate).with(nil).once
    end

    it "test not nil" do
      expect(operator.evaluate(evaluator, true)).to be_falsey
      expect(evaluator).to have_received(:evaluate).with(true).once

      expect(operator.evaluate(evaluator, false)).to be_falsey
      expect(evaluator).to have_received(:evaluate).with(false).once

      expect(operator.evaluate(evaluator, 0)).to be_falsey
      expect(evaluator).to have_received(:evaluate).with(0).once
    end
  end
end

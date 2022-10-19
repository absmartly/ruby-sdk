# frozen_string_literal: true

require_relative "./shared_operator"
require "json_expr/operators/not_operator"

RSpec.describe NotOperator do
  include_examples "shared operator"

  let(:operator) { described_class.new }
  describe ".evaluate" do
    it "test false" do
      expect(operator.evaluate(evaluator, false)).to be_truthy
      expect(evaluator).to have_received(:evaluate).with(false).once
      expect(evaluator).to have_received(:boolean_convert).with(false).once
    end

    it "test true" do
      expect(operator.evaluate(evaluator, true)).to be_falsey
      expect(evaluator).to have_received(:evaluate).with(true).once
      expect(evaluator).to have_received(:boolean_convert).with(true).once
    end

    it "test nil" do
      expect(operator.evaluate(evaluator, nil)).to be_truthy
      expect(evaluator).to have_received(:evaluate).with(nil).once
      expect(evaluator).to have_received(:boolean_convert).with(nil).once
    end
  end
end

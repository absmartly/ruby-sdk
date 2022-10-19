# frozen_string_literal: true

require_relative "./shared_operator"
require "json_expr/operators/var_operator"

RSpec.describe VarOperator do
  include_examples "shared operator"

  let(:operator) { described_class.new }
  describe ".evaluate" do
    it "test evaluate" do
      expect(operator.evaluate(evaluator, "a/b/c")).to eq("abc")
      expect(evaluator).to have_received(:extract_var).once
      expect(evaluator).to have_received(:extract_var).with("a/b/c").once
      expect(evaluator).to have_received(:evaluate).exactly(0).time
    end
  end
end

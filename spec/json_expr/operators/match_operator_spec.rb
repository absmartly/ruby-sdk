# frozen_string_literal: true

require_relative "./shared_operator"
require "json_expr/operators/match_operator"

RSpec.describe MatchOperator do
  include_examples "shared operator"

  let(:operator) { described_class.new }
  describe ".evaluate" do
    it "test evaluate" do
      expect(operator.evaluate(evaluator, ["abcdefghijk", ""])).to be_truthy
      expect(operator.evaluate(evaluator, ["abcdefghijk", "abc"])).to be_truthy
      expect(operator.evaluate(evaluator, ["abcdefghijk", "ijk"])).to be_truthy
      expect(operator.evaluate(evaluator, ["abcdefghijk", "^abc"])).to be_truthy
      expect(operator.evaluate(evaluator, ["abcdefghijk", "ijk$"])).to be_truthy
      expect(operator.evaluate(evaluator, ["abcdefghijk", "def"])).to be_truthy
      expect(operator.evaluate(evaluator, ["abcdefghijk", "b.*j"])).to be_truthy
      expect(operator.evaluate(evaluator, ["abcdefghijk", "xyz"])).to be_falsey

      expect(operator.evaluate(evaluator, [nil, "abc"])).to be_nil
      expect(operator.evaluate(evaluator, ["abcdefghijk", nil])).to be_nil
    end
  end
end

# frozen_string_literal: true

require_relative "./shared_operator"
require "json_expr/operators/in_operator"

RSpec.describe InOperator do
  include_examples "shared operator"

  let(:operator) { described_class.new }
  describe ".evaluate" do
    it "test string" do
      expect(operator.evaluate(evaluator, ["abcdefghijk", "abc"])).to be_truthy
      expect(operator.evaluate(evaluator, ["abcdefghijk", "def"])).to be_truthy
      expect(operator.evaluate(evaluator, ["abcdefghijk", "xxx"])).to be_falsey
      expect(operator.evaluate(evaluator, ["abcdefghijk", nil])).to be_nil
      expect(operator.evaluate(evaluator, [nil, "abc"])).to be_nil

      expect(evaluator).to have_received(:evaluate).with("abcdefghijk").exactly(4).time
      expect(evaluator).to have_received(:evaluate).with("abc").once
      expect(evaluator).to have_received(:evaluate).with("def").once
      expect(evaluator).to have_received(:evaluate).with("xxx").once

      expect(evaluator).to have_received(:string_convert).with("abc").once
      expect(evaluator).to have_received(:string_convert).with("def").once
      expect(evaluator).to have_received(:string_convert).with("xxx").once
    end

    it "test array empty" do
      expect(operator.evaluate(evaluator, [[], 1])).to be_falsey
      expect(operator.evaluate(evaluator, [[], "1"])).to be_falsey
      expect(operator.evaluate(evaluator, [[], true])).to be_falsey
      expect(operator.evaluate(evaluator, [[], false])).to be_falsey
      expect(operator.evaluate(evaluator, [[], nil])).to be_nil

      expect(evaluator).to have_received(:boolean_convert).exactly(0).time
      expect(evaluator).to have_received(:number_convert).exactly(0).time
      expect(evaluator).to have_received(:string_convert).exactly(0).time
      expect(evaluator).to have_received(:compare).exactly(0).time
    end

    it "test array compare" do
      haystack01 = [0, 1]
      haystack12 = [1, 2]
      expect(operator.evaluate(evaluator, [haystack01, 2])).to be_falsey
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystack01).once
      expect(evaluator).to have_received(:evaluate).with(2).once
      haystack01.each do |haystack|
        expect(evaluator).to have_received(:compare).with(haystack, 2).once
      end

      reset_evaluator
      expect(operator.evaluate(evaluator, [haystack12, 0])).to be_falsey
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystack12).once
      expect(evaluator).to have_received(:evaluate).with(0).once
      haystack12.each do |haystack|
        expect(evaluator).to have_received(:compare).with(haystack, 0).once
      end

      reset_evaluator
      expect(operator.evaluate(evaluator, [haystack12, 1])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystack12).once
      expect(evaluator).to have_received(:evaluate).with(1).once
      expect(evaluator).to have_received(:compare).with(1, 1).once

      reset_evaluator
      expect(operator.evaluate(evaluator, [haystack12, 2])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystack12).once
      expect(evaluator).to have_received(:evaluate).with(2).once
      haystack12.each do |haystack|
        expect(evaluator).to have_received(:compare).with(haystack, 2).once
      end
    end

    it "test object contains key" do
      haystackab = { "a" => 1, "b" => 2 }
      haystackbc = { "b" => 2, "c" => 3, "0" => 100 }

      expect(operator.evaluate(evaluator, [haystackab, "c"])).to be_falsey
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystackab).once
      expect(evaluator).to have_received(:evaluate).with("c").once
      expect(evaluator).to have_received(:string_convert).with("c").once

      reset_evaluator
      expect(operator.evaluate(evaluator, [haystackbc, "a"])).to be_falsey
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystackbc).once
      expect(evaluator).to have_received(:evaluate).with("a").once
      expect(evaluator).to have_received(:string_convert).with("a").once

      reset_evaluator
      expect(operator.evaluate(evaluator, [haystackbc, "b"])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystackbc).once
      expect(evaluator).to have_received(:evaluate).with("b").once
      expect(evaluator).to have_received(:string_convert).with("b").once

      reset_evaluator
      expect(operator.evaluate(evaluator, [haystackbc, "c"])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystackbc).once
      expect(evaluator).to have_received(:evaluate).with("c").once
      expect(evaluator).to have_received(:string_convert).with("c").once

      reset_evaluator
      expect(operator.evaluate(evaluator, [haystackbc, 0])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystackbc).once
      expect(evaluator).to have_received(:evaluate).with(0).once
      expect(evaluator).to have_received(:string_convert).with(0).once
    end
  end
end

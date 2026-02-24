# frozen_string_literal: true

require_relative "./shared_operator"
require "json_expr/operators/in_operator"

RSpec.describe InOperator do
  include_examples "shared operator"

  let(:operator) { described_class.new }
  describe ".evaluate" do
    it "test string" do
      expect(operator.evaluate(evaluator, ["abc", "abcdefghijk"])).to be_truthy
      expect(operator.evaluate(evaluator, ["def", "abcdefghijk"])).to be_truthy
      expect(operator.evaluate(evaluator, ["xxx", "abcdefghijk"])).to be_falsey
      expect(operator.evaluate(evaluator, [nil, "abcdefghijk"])).to be_nil
      expect(operator.evaluate(evaluator, ["abc", nil])).to be_nil

      expect(evaluator).to have_received(:evaluate).with("abcdefghijk").exactly(3).time
      expect(evaluator).to have_received(:evaluate).with("abc").twice
      expect(evaluator).to have_received(:evaluate).with("def").once
      expect(evaluator).to have_received(:evaluate).with("xxx").once

      expect(evaluator).to have_received(:string_convert).with("abc").once
      expect(evaluator).to have_received(:string_convert).with("def").once
      expect(evaluator).to have_received(:string_convert).with("xxx").once
    end

    it "test array empty" do
      expect(operator.evaluate(evaluator, [1, []])).to be_falsey
      expect(operator.evaluate(evaluator, ["1", []])).to be_falsey
      expect(operator.evaluate(evaluator, [true, []])).to be_falsey
      expect(operator.evaluate(evaluator, [false, []])).to be_falsey
      expect(operator.evaluate(evaluator, [nil, []])).to be_nil

      expect(evaluator).to have_received(:boolean_convert).exactly(0).time
      expect(evaluator).to have_received(:number_convert).exactly(0).time
      expect(evaluator).to have_received(:string_convert).exactly(0).time
      expect(evaluator).to have_received(:compare).exactly(0).time
    end

    it "test array compare" do
      haystack01 = [0, 1]
      haystack12 = [1, 2]
      expect(operator.evaluate(evaluator, [2, haystack01])).to be_falsey
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystack01).once
      expect(evaluator).to have_received(:evaluate).with(2).once
      haystack01.each do |item|
        expect(evaluator).to have_received(:compare).with(item, 2).once
      end

      reset_evaluator
      expect(operator.evaluate(evaluator, [0, haystack12])).to be_falsey
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystack12).once
      expect(evaluator).to have_received(:evaluate).with(0).once
      haystack12.each do |item|
        expect(evaluator).to have_received(:compare).with(item, 0).once
      end

      reset_evaluator
      expect(operator.evaluate(evaluator, [1, haystack12])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystack12).once
      expect(evaluator).to have_received(:evaluate).with(1).once
      expect(evaluator).to have_received(:compare).with(1, 1).once

      reset_evaluator
      expect(operator.evaluate(evaluator, [2, haystack12])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystack12).once
      expect(evaluator).to have_received(:evaluate).with(2).once
      haystack12.each do |item|
        expect(evaluator).to have_received(:compare).with(item, 2).once
      end
    end

    it "test object contains key" do
      haystackab = { "a" => 1, "b" => 2 }
      haystackbc = { "b" => 2, "c" => 3, "0" => 100 }

      expect(operator.evaluate(evaluator, ["c", haystackab])).to be_falsey
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystackab).once
      expect(evaluator).to have_received(:evaluate).with("c").once
      expect(evaluator).to have_received(:string_convert).with("c").once

      reset_evaluator
      expect(operator.evaluate(evaluator, ["a", haystackbc])).to be_falsey
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystackbc).once
      expect(evaluator).to have_received(:evaluate).with("a").once
      expect(evaluator).to have_received(:string_convert).with("a").once

      reset_evaluator
      expect(operator.evaluate(evaluator, ["b", haystackbc])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystackbc).once
      expect(evaluator).to have_received(:evaluate).with("b").once
      expect(evaluator).to have_received(:string_convert).with("b").once

      reset_evaluator
      expect(operator.evaluate(evaluator, ["c", haystackbc])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystackbc).once
      expect(evaluator).to have_received(:evaluate).with("c").once
      expect(evaluator).to have_received(:string_convert).with("c").once

      reset_evaluator
      expect(operator.evaluate(evaluator, [0, haystackbc])).to be_truthy
      expect(evaluator).to have_received(:evaluate).twice
      expect(evaluator).to have_received(:evaluate).with(haystackbc).once
      expect(evaluator).to have_received(:evaluate).with(0).once
      expect(evaluator).to have_received(:string_convert).with(0).once
    end
  end
end

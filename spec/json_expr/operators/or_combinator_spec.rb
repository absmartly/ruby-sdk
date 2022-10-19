# frozen_string_literal: true

require_relative "./shared_operator"
require "json_expr/operators/or_combinator"

RSpec.describe OrCombinator do
  include_examples "shared operator"

  let(:combinator) { described_class.new }
  describe ".combine" do
    it "test combine true" do
      expect(combinator.combine(evaluator, [true])).to be_truthy
      expect(evaluator).to have_received(:evaluate).with(true).once
      expect(evaluator).to have_received(:boolean_convert).with(true).once
    end

    it "test combine false" do
      expect(combinator.combine(evaluator, [false])).to be_falsey
      expect(evaluator).to have_received(:evaluate).with(false).once
      expect(evaluator).to have_received(:boolean_convert).with(false).once
    end

    it "test combine nil" do
      expect(combinator.combine(evaluator, [nil])).to be_falsey
      expect(evaluator).to have_received(:evaluate).with(nil).once
      expect(evaluator).to have_received(:boolean_convert).with(nil).once
    end

    it "test combine short circuit" do
      expect(combinator.combine(evaluator, [true, false, true])).to be_truthy

      expect(evaluator).to have_received(:evaluate).with(true).once
      expect(evaluator).to have_received(:boolean_convert).with(true).once

      expect(evaluator).to have_received(:evaluate).with(false).exactly(0).time
      expect(evaluator).to have_received(:boolean_convert).with(false).exactly(0).time
    end

    it "test combine" do
      expect(combinator.combine(evaluator, [true, true])).to be_truthy
      expect(combinator.combine(evaluator, [true, true, true])).to be_truthy

      expect(combinator.combine(evaluator, [true, false])).to be_truthy
      expect(combinator.combine(evaluator, [false, true])).to be_truthy
      expect(combinator.combine(evaluator, [false, false])).to be_falsey
      expect(combinator.combine(evaluator, [false, false, false])).to be_falsey
    end
  end
end

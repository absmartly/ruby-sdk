# frozen_string_literal: true

require "json_expr/expr_evaluator"
require "json_expr/operator"
require "json_expr/evaluator"

RSpec.describe ExprEvaluator do
  describe ".evaluate" do
    it "considers list as and combinator" do
      and_operator = instance_double(Operator)
      allow(and_operator).to receive(:evaluate).and_return('value': true)
      or_operator = instance_double(Operator)
      allow(or_operator).to receive(:evaluate).and_return('value': true)
      expect(and_operator.evaluate(EMPTY_MAP, EMPTY_MAP)).to eq('value': true)

      evaluator = described_class.new({ 'and': and_operator, 'or': or_operator }, EMPTY_MAP)
      args = [{ 'value': true }, { 'value': false }]
      expect(evaluator.evaluate(args)).not_to be_nil

      expect(or_operator).to have_received(:evaluate).exactly(0).time
      expect(and_operator).to have_received(:evaluate).with(evaluator, args).once
    end

    it "returns null if operator not found" do
      value_operator = instance_double(Operator)
      allow(value_operator).to receive(:evaluate).and_return('value': true)

      evaluator = described_class.new({ 'value': value_operator }, EMPTY_MAP)
      expect(evaluator.evaluate('not_found': true)).to be_nil

      expect(value_operator).to have_received(:evaluate).exactly(0).time
    end

    it "returns the args if calls operator with args" do
      value_operator = instance_double(Operator)

      args = [1, 2, 3]

      allow(value_operator).to receive(:evaluate).with(Evaluator, args).and_return(args)

      evaluator = described_class.new({ value: value_operator }, EMPTY_MAP)
      expect(evaluator.evaluate(value: args)).to eq(args)

      expect(value_operator).to have_received(:evaluate).with(Evaluator, args).once
    end

    it "test boolean convert" do
      evaluator = described_class.new(EMPTY_MAP, EMPTY_MAP)
      expect(evaluator.boolean_convert(EMPTY_LIST)).to be_truthy
      expect(evaluator.boolean_convert(EMPTY_MAP)).to be_truthy
      expect(evaluator.boolean_convert(nil)).to be_falsey

      expect(evaluator.boolean_convert(true)).to be_truthy
      expect(evaluator.boolean_convert(1)).to be_truthy
      expect(evaluator.boolean_convert(2)).to be_truthy
      expect(evaluator.boolean_convert("abc")).to be_truthy
      expect(evaluator.boolean_convert("1")).to be_truthy

      expect(evaluator.boolean_convert(false)).to be_falsey
      expect(evaluator.boolean_convert(0)).to be_falsey
      expect(evaluator.boolean_convert("")).to be_falsey
      expect(evaluator.boolean_convert("0")).to be_falsey
      expect(evaluator.boolean_convert("false")).to be_falsey
    end

    it "test number convert" do
      evaluator = described_class.new(EMPTY_MAP, EMPTY_MAP)

      expect(evaluator.number_convert(EMPTY_LIST)).to be_nil
      expect(evaluator.number_convert(EMPTY_MAP)).to be_nil
      expect(evaluator.number_convert(nil)).to be_nil
      expect(evaluator.number_convert("")).to be_nil
      expect(evaluator.number_convert("abcd")).to be_nil
      expect(evaluator.number_convert("x1234")).to be_nil

      expect(evaluator.number_convert(true)).to eq(1.0)
      expect(evaluator.number_convert(false)).to eq(0.0)

      expect(evaluator.number_convert(-1.0)).to eq(-1.0)
      expect(evaluator.number_convert(0.0)).to eq(0.0)
      expect(evaluator.number_convert(1.5)).to eq(1.5)
      expect(evaluator.number_convert(2.0)).to eq(2.0)
      expect(evaluator.number_convert(3.0)).to eq(3.0)

      expect(evaluator.number_convert(-1)).to eq(-1.0)
      expect(evaluator.number_convert(0)).to eq(0.0)
      expect(evaluator.number_convert(1)).to eq(1.0)
      expect(evaluator.number_convert(2)).to eq(2.0)
      expect(evaluator.number_convert(3)).to eq(3.0)
      expect(evaluator.number_convert(2147483647)).to eq(2147483647.0)
      expect(evaluator.number_convert(-2147483647)).to eq(-2147483647.0)
      expect(evaluator.number_convert(9007199254740991)).to eq(9007199254740991.0)
      expect(evaluator.number_convert(-9007199254740991)).to eq(-9007199254740991.0)

      expect(evaluator.number_convert("-1")).to eq(-1.0)
      expect(evaluator.number_convert("0")).to eq(0.0)
      expect(evaluator.number_convert("1")).to eq(1.0)
      expect(evaluator.number_convert("1.5")).to eq(1.5)
      expect(evaluator.number_convert("2")).to eq(2.0)
      expect(evaluator.number_convert("3.0")).to eq(3.0)
    end

    it "test string convert" do
      evaluator = described_class.new(EMPTY_MAP, EMPTY_MAP)

      expect(evaluator.string_convert(nil)).to be_nil
      expect(evaluator.string_convert(EMPTY_MAP)).to be_nil
      expect(evaluator.string_convert(EMPTY_LIST)).to be_nil

      expect(evaluator.string_convert(true)).to eq("true")
      expect(evaluator.string_convert(false)).to eq("false")

      expect(evaluator.string_convert("")).to eq("")
      expect(evaluator.string_convert("abc")).to eq("abc")

      expect(evaluator.string_convert(-1.0)).to eq("-1")
      expect(evaluator.string_convert(0.0)).to eq("0")
      expect(evaluator.string_convert(1)).to eq("1")
      expect(evaluator.string_convert(1.5)).to eq("1.5")
      expect(evaluator.string_convert(2.0)).to eq("2")
      expect(evaluator.string_convert(3.0)).to eq("3")
      expect(evaluator.string_convert(2147483647.0)).to eq("2147483647")
      expect(evaluator.string_convert(-2147483647.0)).to eq("-2147483647")
      expect(evaluator.string_convert(9007199254740991.0)).to eq("9007199254740991")
      expect(evaluator.string_convert(-9007199254740991.0)).to eq("-9007199254740991")
      expect(evaluator.string_convert(0.9007199254740991)).to eq("0.9007199254740991")
      expect(evaluator.string_convert(-0.9007199254740991)).to eq("-0.9007199254740991")

      expect(evaluator.string_convert(-1)).to eq("-1")
      expect(evaluator.string_convert(0.0)).to eq("0")
      expect(evaluator.string_convert(1)).to eq("1")
      expect(evaluator.string_convert(2)).to eq("2")
      expect(evaluator.string_convert(3)).to eq("3")
      expect(evaluator.string_convert(2147483647)).to eq("2147483647")
      expect(evaluator.string_convert(-2147483647)).to eq("-2147483647")
      expect(evaluator.string_convert(9007199254740991)).to eq("9007199254740991")
      expect(evaluator.string_convert(-9007199254740991)).to eq("-9007199254740991")
    end

    it "test extract var" do
      vars = {
        "a" => 1,
        "b" => true,
        "c" => false,
        "d" => [1, 2, 3],
        "e" => [1, { "z" => 2 }, 3],
        "f" => { "y" => { "x" => 3, "0" => 10 } }
      }

      evaluator = described_class.new(EMPTY_MAP, vars)

      expect(evaluator.extract_var("a")).to eq(1)
      expect(evaluator.extract_var("b")).to eq(true)
      expect(evaluator.extract_var("c")).to eq(false)
      expect(evaluator.extract_var("d")).to eq([1, 2, 3])
      expect(evaluator.extract_var("e")).to eq([1, { "z" => 2 }, 3])
      expect(evaluator.extract_var("f")).to eq("y" => { "x" => 3, "0" => 10 })

      expect(evaluator.extract_var("a/0")).to be_nil
      expect(evaluator.extract_var("a/b")).to be_nil
      expect(evaluator.extract_var("b/0")).to be_nil
      expect(evaluator.extract_var("b/e")).to be_nil

      expect(evaluator.extract_var("d/0")).to eq(1)
      expect(evaluator.extract_var("d/1")).to eq(2)
      expect(evaluator.extract_var("d/2")).to eq(3)
      expect(evaluator.extract_var("d/3")).to be_nil

      expect(evaluator.extract_var("e/0")).to eq(1)
      expect(evaluator.extract_var("e/1/z")).to eq(2)
      expect(evaluator.extract_var("e/2")).to eq(3)
      expect(evaluator.extract_var("e/1/0")).to be_nil

      expect(evaluator.extract_var("f/y")).to eq("x" => 3, "0" => 10)
      expect(evaluator.extract_var("f/y/x")).to eq(3)
      expect(evaluator.extract_var("f/y/0")).to eq(10)
    end

    it "test compare null" do
      evaluator = described_class.new(EMPTY_MAP, EMPTY_MAP)

      expect(evaluator.compare(nil, nil)).to eq(0)

      expect(evaluator.compare(nil, 0)).to be_nil
      expect(evaluator.compare(nil, 1)).to be_nil
      expect(evaluator.compare(nil, true)).to be_nil
      expect(evaluator.compare(nil, false)).to be_nil
      expect(evaluator.compare(nil, "")).to be_nil
      expect(evaluator.compare(nil, "abc")).to be_nil
      expect(evaluator.compare(nil, EMPTY_MAP)).to be_nil
      expect(evaluator.compare(nil, EMPTY_LIST)).to be_nil
    end

    it "test compare objects" do
      evaluator = described_class.new(EMPTY_MAP, EMPTY_MAP)

      expect(evaluator.compare(EMPTY_MAP, 0)).to be_nil
      expect(evaluator.compare(EMPTY_MAP, 1)).to be_nil
      expect(evaluator.compare(EMPTY_MAP, true)).to be_nil
      expect(evaluator.compare(EMPTY_MAP, false)).to be_nil
      expect(evaluator.compare(EMPTY_MAP, "")).to be_nil
      expect(evaluator.compare(EMPTY_MAP, "abc")).to be_nil
      expect(evaluator.compare(EMPTY_MAP, EMPTY_MAP)).to eq(0)
      expect(evaluator.compare({ "a" => 1 }, { "a" => 1 })).to eq(0)
      expect(evaluator.compare({ "a" => 1 }, { "b" => 2 })).to be_nil
      expect(evaluator.compare(EMPTY_MAP, EMPTY_LIST)).to be_nil

      expect(evaluator.compare(EMPTY_LIST, 0)).to be_nil
      expect(evaluator.compare(EMPTY_LIST, 1)).to be_nil
      expect(evaluator.compare(EMPTY_LIST, true)).to be_nil
      expect(evaluator.compare(EMPTY_LIST, false)).to be_nil
      expect(evaluator.compare(EMPTY_LIST, "")).to be_nil
      expect(evaluator.compare(EMPTY_LIST, "abc")).to be_nil
      expect(evaluator.compare(EMPTY_LIST, EMPTY_MAP)).to be_nil
      expect(evaluator.compare(EMPTY_LIST, EMPTY_LIST)).to eq(0)
      expect(evaluator.compare([1, 2], [1, 2])).to eq(0)
      expect(evaluator.compare([1, 2], [3, 4])).to be_nil
    end

    it "test compare booleans" do
      evaluator = described_class.new(EMPTY_MAP, EMPTY_MAP)

      expect(evaluator.compare(false, 0)).to eq(0)
      expect(evaluator.compare(false, 1)).to eq(-1)
      expect(evaluator.compare(false, true)).to eq(-1)
      expect(evaluator.compare(false, false)).to eq(0)
      expect(evaluator.compare(false, "")).to eq(0)
      expect(evaluator.compare(false, "abc")).to eq(-1)
      expect(evaluator.compare(false, EMPTY_MAP)).to eq(-1)
      expect(evaluator.compare(false, EMPTY_LIST)).to eq(-1)

      expect(evaluator.compare(true, 0)).to eq(1)
      expect(evaluator.compare(true, 1)).to eq(0)
      expect(evaluator.compare(true, true)).to eq(0)
      expect(evaluator.compare(true, false)).to eq(1)
      expect(evaluator.compare(true, "")).to eq(1)
      expect(evaluator.compare(true, "abc")).to eq(0)
      expect(evaluator.compare(true, EMPTY_MAP)).to eq(0)
      expect(evaluator.compare(true, EMPTY_LIST)).to eq(0)
    end

    it "test compare numbers" do
      evaluator = described_class.new(EMPTY_MAP, EMPTY_MAP)

      expect(evaluator.compare(0, 0)).to eq(0)
      expect(evaluator.compare(0, 1)).to eq(-1)
      expect(evaluator.compare(0, true)).to eq(-1)
      expect(evaluator.compare(0, false)).to eq(0)
      expect(evaluator.compare(0, "")).to be_nil
      expect(evaluator.compare(0, "abc")).to be_nil
      expect(evaluator.compare(0, EMPTY_MAP)).to be_nil
      expect(evaluator.compare(0, EMPTY_LIST)).to be_nil

      expect(evaluator.compare(1, 0)).to eq(1)
      expect(evaluator.compare(1, 1)).to eq(0)
      expect(evaluator.compare(1, true)).to eq(0)
      expect(evaluator.compare(1, false)).to eq(1)
      expect(evaluator.compare(1, "")).to be_nil
      expect(evaluator.compare(1, "abc")).to be_nil
      expect(evaluator.compare(1, EMPTY_MAP)).to be_nil
      expect(evaluator.compare(1, EMPTY_LIST)).to be_nil

      expect(evaluator.compare(1.0, 1)).to eq(0)
      expect(evaluator.compare(1.5, 1)).to eq(1)
      expect(evaluator.compare(2.0, 1)).to eq(1)
      expect(evaluator.compare(3.0, 1)).to eq(1)

      expect(evaluator.compare(1, 1.0)).to eq(0)
      expect(evaluator.compare(1, 1.5)).to eq(-1)
      expect(evaluator.compare(1, 2.0)).to eq(-1)
      expect(evaluator.compare(1, 3.0)).to eq(-1)

      expect(evaluator.compare(9007199254740991, 9007199254740991)).to eq(0)
      expect(evaluator.compare(0, 9007199254740991)).to eq(-1)
      expect(evaluator.compare(9007199254740991, 0)).to eq(1)

      expect(evaluator.compare(9007199254740991.0, 9007199254740991.0)).to eq(0)
      expect(evaluator.compare(0.0, 9007199254740991.0)).to eq(-1)
      expect(evaluator.compare(9007199254740991.0, 0.0)).to eq(1)
    end

    it "test compare strings" do
      evaluator = described_class.new(EMPTY_MAP, EMPTY_MAP)

      expect(evaluator.compare("", "")).to eq(0)
      expect(evaluator.compare("abc", "abc")).to eq(0)
      expect(evaluator.compare("0", 0)).to eq(0)
      expect(evaluator.compare("1", 1)).to eq(0)
      expect(evaluator.compare("true", true)).to eq(0)
      expect(evaluator.compare("false", false)).to eq(0)
      expect(evaluator.compare("", EMPTY_MAP)).to be_nil
      expect(evaluator.compare("abc", EMPTY_MAP)).to be_nil
      expect(evaluator.compare("", EMPTY_LIST)).to be_nil
      expect(evaluator.compare("abc", EMPTY_LIST)).to be_nil

      expect(evaluator.compare("abc", "bcd")).to eq(-1)
      expect(evaluator.compare("bcd", "abc")).to eq(1)
      expect(evaluator.compare("0", "1")).to eq(-1)
      expect(evaluator.compare("1", "0")).to eq(1)
      expect(evaluator.compare("9", "100")).to eq(8)
      expect(evaluator.compare("100", "9")).to eq(-8)
    end
  end
end

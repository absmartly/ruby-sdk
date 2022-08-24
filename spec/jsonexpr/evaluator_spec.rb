# frozen_string_literal: true

RSpec.describe Absmartly::Jsonexpr::Evaluator do
  context "evaluate" do
    it "should consider an array as implicit AND combinator" do
    end

    it "should return null if operator not found" do
    end

    it "should call operator evaluate will args" do
    end
  end

  context "booleanConvert()" do
    it "should convert all types of values to boolean" do
    end
  end

  context "numberConvert()" do
    it "should convert boolean, and numeric strings to number" do
    end
  end

  context "stringConvert()" do
  end

  context "extractVar()" do
    it "should find data by paths delimited by /" do
    end
  end

  context "compare()" do
    it "should return null if comparing non-null with null" do
    end

    it "should return null if comparing non-object with object" do
    end

    it "should coerce right-side argument to boolean and compare" do
    end

    it "should coerce right-side argument to boolean and compare" do
    end

    it "should coerce right-hand side argument to string and compare" do
    end
  end
end

# frozen_string_literal: true

require "json_expr/json_expr"
require "json_expr/semver_comparator"

RSpec.describe SemverComparator do
  let(:json_expr) { JsonExpr.new }
  let(:evaluator) { ExprEvaluator.new(json_expr.operators, {}) }

  def compare(lhs, rhs)
    described_class.compare(evaluator, lhs, rhs)
  end

  it "compares core versions numerically" do
    expect(compare("1.2.3", "1.2.3")).to eq(0)
    expect(compare("1.10.0", "1.9.9")).to eq(1)
    expect(compare("1.9.9", "1.10.0")).to eq(-1)
    expect(compare("2.0.0", "10.0.0")).to eq(-1)
  end

  it "treats missing core parts as 0" do
    expect(compare("1.2", "1.2.0")).to eq(0)
    expect(compare("1", "1.0.0")).to eq(0)
    expect(compare("1.2", "1.2.1")).to eq(-1)
    expect(compare("1.2.0.1", "1.2")).to eq(1)
  end

  it "ignores a leading v or V" do
    expect(compare("v1.2.3", "1.2.3")).to eq(0)
    expect(compare("V1.2.3", "v1.2.3")).to eq(0)
  end

  it "ignores build metadata" do
    expect(compare("1.2.3+build.1", "1.2.3+build.2")).to eq(0)
    expect(compare("1.2.3-alpha+001", "1.2.3-alpha")).to eq(0)
  end

  it "ignores leading zeros in numeric identifiers" do
    expect(compare("01.002.3", "1.2.3")).to eq(0)
    expect(compare("1.0.0-alpha.01", "1.0.0-alpha.1")).to eq(0)
  end

  it "ranks a release above its pre-releases" do
    expect(compare("1.0.0", "1.0.0-alpha")).to eq(1)
    expect(compare("1.0.0-rc.1", "1.0.0")).to eq(-1)
  end

  it "orders pre-releases as semver does" do
    order = %w[1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0]
    order.each_cons(2) do |lower, higher|
      expect(compare(lower, higher)).to eq(-1), "#{lower} < #{higher}"
      expect(compare(higher, lower)).to eq(1), "#{higher} > #{lower}"
    end
  end

  it "keeps hyphens inside the pre-release" do
    expect(compare("1.0.0-alpha-1", "1.0.0-alpha-1")).to eq(0)
    expect(compare("1.0.0-alpha-2", "1.0.0-alpha-1")).to eq(1)
  end

  it "compares non-numeric parts as text, below numbers" do
    expect(compare("1.x", "1.0")).to eq(1)
    expect(compare("1.a", "1.b")).to eq(-1)
  end

  it "converts numbers and booleans to text first" do
    expect(compare(2, "2.0.0")).to eq(0)
    expect(compare(1.5, "1.5")).to eq(0)
    expect(compare(true, "true")).to eq(0)
  end

  # Cross-SDK parity: the JavaScript and Java comparators read a trailing
  # hyphen as an empty pre-release, i.e. a release. Change all SDKs together.
  it "treats a trailing hyphen as a release, like the JavaScript and Java SDKs" do
    expect(compare("1.0.0-", "1.0.0")).to eq(0)
    expect(compare("1.0.0-", "1.0.0-alpha")).to eq(1)
    expect(json_expr.evaluate_expr({ "semver_eq" => [{ value: "1.0.0-" }, { value: "1.0.0" }] }, {})).to eq(true)
  end

  it "returns nil when either side is not a version" do
    expect(compare("", "1.0.0")).to be_nil
    expect(compare("1.0.0", "")).to be_nil
    expect(compare("v", "1.0.0")).to be_nil
    expect(compare("+build", "1.0.0")).to be_nil
    expect(compare("-alpha", "1.0.0")).to be_nil
    expect(compare(nil, "1.0.0")).to be_nil
    expect(compare([1], "1.0.0")).to be_nil
    expect(compare({}, "1.0.0")).to be_nil
  end

  describe "operators" do
    def evaluate(op, lhs, rhs)
      json_expr.evaluate_expr({ op => [{ value: lhs }, { value: rhs }] }, {})
    end

    it "evaluates semver_eq" do
      expect(evaluate("semver_eq", "1.2.0", "1.2")).to eq(true)
      expect(evaluate("semver_eq", "1.2.1", "1.2")).to eq(false)
    end

    it "evaluates semver_gt" do
      expect(evaluate("semver_gt", "1.10.0", "1.9.0")).to eq(true)
      expect(evaluate("semver_gt", "1.9.0", "1.9.0")).to eq(false)
    end

    it "evaluates semver_gte" do
      expect(evaluate("semver_gte", "1.9.0", "1.9.0")).to eq(true)
      expect(evaluate("semver_gte", "1.8.0", "1.9.0")).to eq(false)
    end

    it "evaluates semver_lt" do
      expect(evaluate("semver_lt", "1.0.0-beta", "1.0.0")).to eq(true)
      expect(evaluate("semver_lt", "1.0.0", "1.0.0")).to eq(false)
    end

    it "evaluates semver_lte" do
      expect(evaluate("semver_lte", "1.0.0", "1.0.0")).to eq(true)
      expect(evaluate("semver_lte", "1.0.1", "1.0.0")).to eq(false)
    end

    it "returns nil for invalid or missing operands" do
      %w[semver_eq semver_gt semver_gte semver_lt semver_lte].each do |op|
        expect(evaluate(op, "", "1.0.0")).to be_nil
        expect(json_expr.evaluate_expr({ op => [{ value: "1.0.0" }] }, {})).to be_nil
        expect(json_expr.evaluate_expr({ op => [{ var: "missing" }, { value: "1.0.0" }] }, {})).to be_nil
      end
    end

    it "compares an attribute in an audience filter" do
      filter = { semver_gte: [{ var: "app_version" }, { value: "2.4.0" }] }
      expect(json_expr.evaluate_boolean_expr(filter, { "app_version" => "2.10.1" })).to eq(true)
      expect(json_expr.evaluate_boolean_expr(filter, { "app_version" => "2.3.9" })).to eq(false)
      expect(json_expr.evaluate_boolean_expr(filter, {})).to eq(false)
    end
  end
end

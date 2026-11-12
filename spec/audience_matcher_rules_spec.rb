# frozen_string_literal: true

require "audience_matcher"
require "default_audience_deserializer"

RSpec.describe AudienceMatcher, "assignment rules" do
  let(:matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }
  let(:us_attrs) { { "country" => "US" } }
  let(:us) { { eq: [{ var: "country" }, { value: "US" }] } }
  let(:gb) { { eq: [{ var: "country" }, { value: "GB" }] } }

  def assign(variant, conditions: us, environments: [])
    rule = { name: "rule", type: "assign", variant: variant }
    rule[:conditions] = conditions unless conditions == :absent
    rule[:environments] = environments unless environments == :absent
    rule
  end

  def split(percentages)
    { name: "split", type: "split", conditions: us, environments: [], percentages: percentages }
  end

  def rules(*list)
    JSON.generate(rules: list)
  end

  # Rules are passed as an array: on Ruby 2.7 a trailing Hash in *args would
  # be taken as keyword arguments.
  def evaluate(list, environment: "production", attrs: us_attrs)
    matcher.evaluate_rules(rules(*list), environment, attrs)
  end

  def assigned(variant)
    AudienceMatcher::RuleAction.new(variant, nil)
  end

  def split_of(*fractions)
    AudienceMatcher::RuleAction.new(nil, fractions)
  end

  it "returns nil without rules" do
    expect(matcher.evaluate_rules(nil, "production", {})).to be_nil
    expect(matcher.evaluate_rules("", "production", {})).to be_nil
    expect(matcher.evaluate_rules("{}", "production", {})).to be_nil
    expect(matcher.evaluate_rules('{"rules":[]}', "production", {})).to be_nil
  end

  it "returns nil for malformed rules" do
    expect(matcher.evaluate_rules("not json", "production", {})).to be_nil
    expect(matcher.evaluate_rules("[]", "production", {})).to be_nil
    expect(matcher.evaluate_rules('{"rules":"not an array"}', "production", {})).to be_nil
    expect(matcher.evaluate_rules('{"rules":[null, 5, "x", []]}', "production", {})).to be_nil
  end

  it "matches on conditions" do
    expect(evaluate([assign(1)])).to eq(assigned(1))
    expect(evaluate([assign(1)], attrs: { "country" => "GB" })).to be_nil
    expect(evaluate([assign(1)], attrs: {})).to be_nil
  end

  it "takes the first matching rule" do
    expect(evaluate([assign(1), assign(2)])).to eq(assigned(1))
    expect(evaluate([assign(1, conditions: gb), assign(2)])).to eq(assigned(2))
  end

  it "matches every unit without conditions" do
    expect(evaluate([assign(3, conditions: :absent)])).to eq(assigned(3))
    expect(evaluate([assign(3, conditions: nil)])).to eq(assigned(3))
  end

  it "skips rules whose conditions are not an object or are falsy" do
    expect(evaluate([assign(1, conditions: [us]), assign(2)])).to eq(assigned(2))
    expect(evaluate([assign(1, conditions: "US"), assign(2)])).to eq(assigned(2))
    expect(evaluate([assign(1, conditions: { value: "false" }), assign(2)])).to eq(assigned(2))
    expect(evaluate([assign(1, conditions: { value: 0 }), assign(2)])).to eq(assigned(2))
    expect(evaluate([assign(1, conditions: { value: true })])).to eq(assigned(1))
  end

  it "skips a rule whose conditions raise" do
    allow(matcher.json_expr).to receive(:evaluate_boolean_expr).and_raise(StandardError, "boom")
    expect(evaluate([assign(1)])).to be_nil
  end

  it "scopes rules to environments" do
    expect(evaluate([assign(1, environments: ["staging"])])).to be_nil
    expect(evaluate([assign(2, environments: %w[production staging])])).to eq(assigned(2))
    expect(evaluate([assign(2, environments: %w[production staging])], environment: "staging")).to eq(assigned(2))
    expect(evaluate([assign(1, environments: ["Production"])])).to be_nil
  end

  it "matches every environment with no or an empty environments list" do
    expect(evaluate([assign(1, environments: [])], environment: nil)).to eq(assigned(1))
    expect(evaluate([assign(1, environments: :absent)], environment: nil)).to eq(assigned(1))
    expect(evaluate([assign(1, environments: nil)])).to eq(assigned(1))
    expect(evaluate([assign(1, environments: ["production"])], environment: nil)).to be_nil
  end

  it "skips rules whose environments are not a list" do
    expect(evaluate([assign(1, environments: "production"), assign(2)])).to eq(assigned(2))
  end

  it "skips assign rules without an integer variant" do
    expect(evaluate([assign(nil)])).to be_nil
    expect(evaluate([assign("1")])).to be_nil
    expect(evaluate([assign(1.5), assign(2)])).to eq(assigned(2))
    expect(evaluate([assign(2.0)])).to eq(assigned(2))
  end

  it "skips rules of an unknown type" do
    expect(evaluate([{ type: "other", variant: 1, conditions: us }, assign(2)])).to eq(assigned(2))
    expect(evaluate([{ variant: 1, conditions: us }])).to be_nil
  end

  it "parses split percentages into fractions" do
    expect(evaluate([split("20/30/50")])).to eq(split_of(0.2, 0.3, 0.5))
    expect(evaluate([split("100")])).to eq(split_of(1.0))
    expect(evaluate([split("0/100/0")])).to eq(split_of(0.0, 1.0, 0.0))
  end

  it "parses split values like JavaScript's parseFloat" do
    expect(evaluate([split(" 50/50")])).to eq(split_of(0.5, 0.5))
    expect(evaluate([split("50abc/50")])).to eq(split_of(0.5, 0.5))
    expect(evaluate([split("5e1/50")])).to eq(split_of(0.5, 0.5))
    expect(evaluate([split(".5/99.5")])).to eq(split_of(0.005, 0.995))
  end

  it "skips splits that are not a string or have invalid values" do
    expect(evaluate([split(nil), assign(2)])).to eq(assigned(2))
    expect(evaluate([split([50, 50]), assign(2)])).to eq(assigned(2))
    expect(evaluate([split("abc/100"), assign(2)])).to eq(assigned(2))
    expect(evaluate([split("50//50"), assign(2)])).to eq(assigned(2))
    expect(evaluate([split("-10/110"), assign(2)])).to eq(assigned(2))
    expect(evaluate([split("Infinity/0"), assign(2)])).to eq(assigned(2))
    expect(evaluate([split(""), assign(2)])).to eq(assigned(2))
  end

  it "accepts a split within 0.01 of 100 after rounding to two decimals" do
    expect(evaluate([split("50/50.014")])).to eq(split_of(0.5, 0.50014))
    expect(evaluate([split("50/49.995")])).not_to be_nil
    expect(evaluate([split("50/50.015")])).to be_nil
    expect(evaluate([split("50/49.98")])).to be_nil
    expect(evaluate([split("50/50/50")])).to be_nil
  end
end

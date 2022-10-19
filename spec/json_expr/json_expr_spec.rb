# frozen_string_literal: true

require "json_expr/json_expr"

RSpec.describe JsonExpr do
  describe ".evaluate_boolean_expr" do
    def value_for(x)
      { value: x }
    end

    def var_for(x)
      { var: { path: x } }
    end

    def unary_op(op, arg)
      Hash[op, arg].transform_keys(&:to_sym)
    end

    def binary_op(op, lhs, rhs)
      Hash[op, [lhs, rhs]].transform_keys(&:to_sym)
    end

    let(:john) { { age: 20, language: "en-US", returning: false } }
    let(:terry) { { age: 20, language: "en-GB", returning: true } }
    let(:kate) { { age: 50, language: "es-ES", returning: false } }
    let(:maria) { { age: 52, language: "pt-PT", returning: true } }
    let(:json_expr) { described_class.new }
    let(:age_twenty_and_us) {
      [
        binary_op("eq", var_for("age"), value_for(20)),
        binary_op("eq", var_for("language"), value_for("en-US"))
      ]
    }
    let(:age_over_fifty) {
      [
        binary_op("gte", var_for("age"), value_for(50))
      ]
    }
    let(:age_twenty_and_us_or_age_over_fifty) {
      [
        { or: [age_twenty_and_us, age_over_fifty] }
      ]
    }
    let(:returning) { var_for("returning") }
    let(:returning_and_age_twenty_and_us_or_age_over_fifty) {
      [returning, age_twenty_and_us_or_age_over_fifty]
    }
    let(:not_returning_and_spanish) {
      [
        unary_op("not", returning),
        binary_op("eq", var_for("language"), value_for("es-ES"))
      ]
    }

    it "test age twenty as us english" do
      expect(json_expr.evaluate_boolean_expr(age_twenty_and_us, john)).to be_truthy
      expect(json_expr.evaluate_boolean_expr(age_twenty_and_us, terry)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(age_twenty_and_us, kate)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(age_twenty_and_us, maria)).to be_falsey
    end

    it "test age over fifty" do
      expect(json_expr.evaluate_boolean_expr(age_over_fifty, john)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(age_over_fifty, terry)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(age_over_fifty, kate)).to be_truthy
      expect(json_expr.evaluate_boolean_expr(age_over_fifty, maria)).to be_truthy
    end

    it "test age twenty and us or age over fifty" do
      expect(json_expr.evaluate_boolean_expr(age_twenty_and_us_or_age_over_fifty, john)).to be_truthy
      expect(json_expr.evaluate_boolean_expr(age_twenty_and_us_or_age_over_fifty, terry)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(age_twenty_and_us_or_age_over_fifty, kate)).to be_truthy
      expect(json_expr.evaluate_boolean_expr(age_twenty_and_us_or_age_over_fifty, maria)).to be_truthy
    end

    it "test returning" do
      expect(json_expr.evaluate_boolean_expr(returning, john)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(returning, terry)).to be_truthy
      expect(json_expr.evaluate_boolean_expr(returning, kate)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(returning, maria)).to be_truthy
    end

    it "test returning and age twenty and us or age over fifty" do
      expect(json_expr.evaluate_boolean_expr(returning_and_age_twenty_and_us_or_age_over_fifty, john)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(returning_and_age_twenty_and_us_or_age_over_fifty, terry)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(returning_and_age_twenty_and_us_or_age_over_fifty, kate)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(returning_and_age_twenty_and_us_or_age_over_fifty, maria)).to be_truthy
    end

    it "test not returning and spanish" do
      expect(json_expr.evaluate_boolean_expr(not_returning_and_spanish, john)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(not_returning_and_spanish, terry)).to be_falsey
      expect(json_expr.evaluate_boolean_expr(not_returning_and_spanish, kate)).to be_truthy
      expect(json_expr.evaluate_boolean_expr(not_returning_and_spanish, maria)).to be_falsey
    end
  end
end

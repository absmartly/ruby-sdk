# frozen_string_literal: true

require_relative "./expr_evaluator"
Dir["lib/json_expr/operators/*.rb"].each { |file| require "./#{file}" }

class JsonExpr
  attr_accessor :operators
  attr_accessor :vars

  def initialize
    @operators = {
      "and": AndCombinator.new,
      "or": OrCombinator.new,
      "value": ValueOperator.new,
      "var": VarOperator.new,
      "null": NilOperator.new,
      "not": NotOperator.new,
      "in": InOperator.new,
      "match": MatchOperator.new,
      "eq": EqualsOperator.new,
      "gt": GreaterThanOperator.new,
      "gte": GreaterThanOrEqualOperator.new,
      "lt": LessThanOperator.new,
      "lte": LessThanOrEqualOperator.new
    }
  end

  def evaluate_boolean_expr(expr, vars)
    evaluator = ExprEvaluator.new(operators, vars)
    evaluator.boolean_convert(evaluator.evaluate(expr))
  end

  def evaluate_expr(expr, vars)
    evaluator = ExprEvaluator.new(operators, vars)
    evaluator.evaluate(expr)
  end
end

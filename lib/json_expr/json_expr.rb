# frozen_string_literal: true

require_relative "./expr_evaluator"
require 'json_expr/operators/and_combinator'
require 'json_expr/operators/binary_operator'
require 'json_expr/operators/boolean_combinator'
require 'json_expr/operators/equals_operator'
require 'json_expr/operators/greater_than_operator'
require 'json_expr/operators/greater_than_or_equal_operator'
require 'json_expr/operators/in_operator'
require 'json_expr/operators/less_than_operator'
require 'json_expr/operators/less_than_or_equal_operator'
require 'json_expr/operators/match_operator'
require 'json_expr/operators/nil_operator'
require 'json_expr/operators/not_operator'
require 'json_expr/operators/or_combinator'
require 'json_expr/operators/unary_operator'
require 'json_expr/operators/value_operator'
require 'json_expr/operators/var_operator'

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

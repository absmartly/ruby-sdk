# frozen_string_literal: true

require_relative "binary_operator"

class GreaterThanOperator
  include BinaryOperator

  def binary(evaluator, lhs, rhs)
    result = evaluator.compare(lhs, rhs)
    !result.nil? ? (result > 0) : nil
  end
end

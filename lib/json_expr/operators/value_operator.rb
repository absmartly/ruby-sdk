# frozen_string_literal: true

require_relative "binary_operator"

class ValueOperator
  include BinaryOperator

  def evaluate(evaluator, value)
    value
  end
end

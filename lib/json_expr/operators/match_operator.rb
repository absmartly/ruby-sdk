# frozen_string_literal: true

require_relative "binary_operator"

class MatchOperator
  include BinaryOperator

  def binary(evaluator, lhs, rhs)
    text = evaluator.string_convert(lhs)
    unless text.nil?
      pattern = evaluator.string_convert(rhs)
      unless pattern.nil?
        text.match(pattern)
      end
    end
  end
end

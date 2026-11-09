# frozen_string_literal: true

require_relative "binary_operator"

class MatchOperator
  include BinaryOperator

  def binary(evaluator, lhs, rhs)
    text = evaluator.string_convert(lhs)
    return nil if text.nil?

    pattern = evaluator.string_convert(rhs)
    return nil if pattern.nil?

    begin
      Regexp.new(pattern).match?(text)
    rescue RegexpError
      nil
    end
  end
end

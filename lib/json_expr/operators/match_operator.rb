# frozen_string_literal: true

require_relative "binary_operator"

class MatchOperator
  include BinaryOperator
  MAX_PATTERN_LENGTH = 1000
  MAX_TEXT_LENGTH = 10_000

  def binary(evaluator, lhs, rhs)
    text = evaluator.string_convert(lhs)
    return nil if text.nil?

    pattern = evaluator.string_convert(rhs)
    return nil if pattern.nil?

    return nil if pattern.length > MAX_PATTERN_LENGTH
    return nil if text.length > MAX_TEXT_LENGTH

    begin
      Regexp.new(pattern).match?(text)
    rescue RegexpError
      nil
    end
  end
end

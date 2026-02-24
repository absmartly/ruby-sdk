# frozen_string_literal: true

require_relative "binary_operator"

class EqualsOperator
  include BinaryOperator

  def evaluate(evaluator, args)
    if args.is_a? Array
      lhs = args.size > 0 ? evaluator.evaluate(args[0]) : nil
      rhs = args.size > 1 ? evaluator.evaluate(args[1]) : nil
      return true if lhs.nil? && rhs.nil?
      return nil if lhs.nil? || rhs.nil?
      result = evaluator.compare(lhs, rhs)
      return !result.nil? ? (result == 0) : nil
    end
    nil
  end

  def binary(evaluator, lhs, rhs)
    result = evaluator.compare(lhs, rhs)
    !result.nil? ? (result == 0) : nil
  end
end

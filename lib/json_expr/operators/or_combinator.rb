# frozen_string_literal: true

require_relative "boolean_combinator"
require_relative "../../type_utils"

class OrCombinator
  include BooleanCombinator

  def combine(evaluator, exprs)
    wrapped = TypeUtils.wrap_array(exprs)
    wrapped.each do |expr|
      return true if evaluator.boolean_convert(evaluator.evaluate(expr))
    end
    wrapped.empty?
  end
end

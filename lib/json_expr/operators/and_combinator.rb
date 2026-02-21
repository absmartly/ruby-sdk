# frozen_string_literal: true

require_relative "boolean_combinator"
require_relative "../../type_utils"

class AndCombinator
  include BooleanCombinator

  def combine(evaluator, exprs)
    TypeUtils.wrap_array(exprs).each do |expr|
      return false unless evaluator.boolean_convert(evaluator.evaluate(expr))
    end
    true
  end
end

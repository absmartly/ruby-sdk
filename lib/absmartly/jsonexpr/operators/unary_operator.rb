# frozen_string_literal: true

module Absmartly
  module Jsonexpr
    module Operators
      class UnaryOperator
        def evaluate(evaluator, arg)
          arg = evaluator.evaluate(arg)
          unary(evaluator, arg)
        end
      end
    end
  end
end

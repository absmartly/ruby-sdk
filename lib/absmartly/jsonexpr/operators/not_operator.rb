# frozen_string_literal: true
require_relative 'unary_operator'

module Absmartly
  module Jsonexpr
    module Operators
      class NotOperator < UnaryOperator
        def unary(evaluator, arg)
          !evaluator.boolean_convert(arg)
        end
      end
    end
  end
end

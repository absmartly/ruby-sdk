# frozen_string_literal: true
require_relative 'unary_operator'

module Absmartly
  module Jsonexpr
    module Operators
      class NullOperator < UnaryOperator
        def unary(evaluator, value)
          value === nil
        end
      end
    end
  end
end

# frozen_string_literal: true

module Absmartly
  module Jsonexpr
    module Operators
      class AndOperator
        def evaluate(evaluator, args)
          if args.is_a?(Array)
            args.each do |expr|
              if !evaluator.boolean_convert(evaluator.evaluate(expr))
                return false
              end
            end

            return true
          end

          nil
        end
      end
    end
  end
end

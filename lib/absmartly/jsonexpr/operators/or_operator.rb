# frozen_string_literal: true

module Absmartly
  module Jsonexpr
    module Operators
      class OrOperator
        def evaluate(evaluator,args)
          if args.is_a?(Array)
            args.each do |expr|
              if evaluator.boolean_convert(evaluator.evaluate(expr))
                return true
              end
            end
            return args.length === 0
          end
          nil
        end
      end
    end
  end
end

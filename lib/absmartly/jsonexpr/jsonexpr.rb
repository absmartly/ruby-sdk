Dir[File.dirname(__FILE__) + "/operators/*.rb"].each { |file| require_relative file }
require_relative './evaluator'

module Absmartly
  module Jsonexpr
    class Jsonexpr
      OPERATORS = {
          and:   Operators::AndOperator.new,
          or:    Operators::OrOperator.new,
          var:   Operators::VarOperator.new,
          value: Operators::ValueOperator.new,
          null:  Operators::NullOperator.new,
          not:   Operators::NotOperator.new,
          in:    Operators::InOperator.new,
          match: Operators::MatchOperator.new,
          eq:    Operators::EqOperator.new,
          gt:    Operators::GtOperator.new,
          gte:   Operators::GteOperator.new,
          lt:    Operators::LtOperator.new,
          lte:   Operators::LteOperator.new,
      }
      
      def evaluate_boolean_expr(expr, vars)
        evaluator = new Evaluator(OPERATORS, vars)
        evaluator.boolean_convert(evaluator.evaluate(expr))
      end
      
      def evaluate_expr(expr, vars)
        evaluator = new Evaluator(OPERATORS, vars)
        evaluator.evaluate(expr)
      end
    end
  end
end

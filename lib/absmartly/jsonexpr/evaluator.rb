# frozen_string_literal: true

module Absmartly
  module Jsonexpr
    class Evaluator
      attr_reader :operators, :vars

      def initialize(operators:, vars:)
        @operators = operators
        @vars      = vars
      end

      def evaluate(expr)
        if expr.class == Array
          return operators[:and].evaluate(self, expr)
        elsif expr.class == Hash
          expr.each do |key, value|
            op = operators[key]

            if op
              return op.evaluate(self, value)
            end

            break
          end
        end

        nil
      end

      def boolean_convert(x)
        type = x.class

        case type
        when TrueClass || FalseClass
          x
        when Integer || Float
          x != 0
        when String
          x != "false" && x != "0" && x != ""
        else
          !x.nil? && defined?(x)
        end
      end

      def number_convert(x)
        type = x.class

        case type
        when TrueClass || FalseClass
          x.to_s
        when Integer || Float
          # TODO: map this
          # return x.toFixed(15).replace(/\.?0{0,15}$/, "");
          x != 0
        when String
          x
        else
          nil
        end
      end

      def extract_var(path)
        frags  = path.split("/")
        target = vars || Hash.new

        frags.each_with_index do |_val, index|
          frag  = frags[index]
          value = target[frag]

          if value
            target = value
            next
          end

          nil
        end

        target
      end

      def compare(lhs, rhs)
        if lhs.nil?
          return rhs.nil? ? 0 : nil
        elsif rhs.nil?
          return nil
        end

        # TODO: break statements
        case lhs.class
        when TrueClass || FalseClass
          rvalue = self.boolean_convert(rhs)
          if rvalue
            return (lhs == rvalue) ? 0 : (lhs > rvalue) ? 1 : -1
          end
        when Integer || Float
          rvalue = self.number_convert(rhs)
          if rvalue
            return (lhs == rvalue) ? 0 : (lhs > rvalue) ? 1 : -1
          end
        when String
          rvalue = self.string_convert(rhs)
          if rvalue
            return (lhs == rvalue) ? 0 : (lhs > rvalue) ? 1 : -1
          end
        else
          # TODO: implement helper
          # if Helpers.is_equals_deep(lhs, rhs)
          #     return 0;
          # end
        end

        nil
      end
    end
  end
end

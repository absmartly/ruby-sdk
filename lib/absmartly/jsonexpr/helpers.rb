module Absmartly
  module Jsonexpr
    class Helpers
      def self.is_equals_deep(a, b, astack = nil, bstack = nil)
        return true if (a == b)
        return false if (a.class != b.class)
        
        case a.class
          when TrueClass || FalseClass
            return a == b
          when Integer || Float
            #TODO: isNan handling
            return a == b
          when String
            return a == b
          when Hash
            if a.is_a?(Array) && !b.is_a?(Array)
              return false
            end
            
            if a.is_a?(Hash) && !b.is_a?(Hash)
              return false
            end
            
            if !a.is_a?(Array) && !a.is_a?(Hash)
              return false
            end
            
            if a.is_a(Array)
            
            end
          else
            nil
        end
      end
    
    end
  end
end

# frozen_string_literal: true

require "json"
require_relative "json_expr/json_expr"

class AudienceMatcher
  attr_accessor :deserializer, :json_expr

  def initialize(deserializer)
    @deserializer = deserializer
    @json_expr = JsonExpr.new
  end

  class Result
    attr_accessor :result

    def initialize(result)
      @result = result
    end

    def get
      @result
    end
  end

  def evaluate(audience, attributes)
    audience_map = JSON.parse(audience, symbolize_names: true)

    unless audience_map.nil?
      filter = audience_map[:filter]
      if filter.is_a?(Hash) || filter.is_a?(Array)
        Result.new(@json_expr.evaluate_boolean_expr(filter, attributes))
      end
    end
  rescue
    nil
  end
end

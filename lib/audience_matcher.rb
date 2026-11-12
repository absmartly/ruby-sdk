# frozen_string_literal: true

require "json"
require_relative "json_expr/json_expr"

class AudienceMatcher
  attr_accessor :deserializer, :json_expr

  SPLIT_PERCENTAGES_SUM_TOLERANCE = 0.01
  # The longest decimal prefix JavaScript's parseFloat accepts.
  FLOAT_PREFIX = /\A\s*([+-]?(?:Infinity|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?))/.freeze

  # The action of the first matching assignment rule: a fixed variant, or a
  # split (one fraction per variant) to randomize the unit over.
  RuleAction = Struct.new(:variant, :split) do
    def split?
      !split.nil?
    end
  end

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
  rescue StandardError
    nil
  end

  # Returns the rules array of an assignmentRules JSON string, or nil when it
  # is not valid JSON or has no rules array.
  def parse_rules(assignment_rules)
    return nil unless assignment_rules.is_a?(String)

    parsed = JSON.parse(assignment_rules)
    rules = parsed["rules"] if parsed.is_a?(Hash)
    rules.is_a?(Array) ? rules : nil
  rescue JSON::ParserError
    nil
  end

  def evaluate_rules(assignment_rules, environment, attributes)
    rules = parse_rules(assignment_rules)
    rules.nil? ? nil : evaluate_parsed_rules(rules, environment, attributes)
  end

  # The first rule whose action is valid, whose environments include the
  # environment (none or an empty list match all) and whose conditions
  # evaluate to true wins. Any other rule is skipped.
  def evaluate_parsed_rules(rules, environment, attributes)
    rules.each do |rule|
      next unless rule.is_a?(Hash)

      action = parse_rule_action(rule)
      next if action.nil?

      environments = rule["environments"]
      unless environments.nil?
        next unless environments.is_a?(Array)
        next if !environments.empty? && (environment.nil? || !environments.include?(environment))
      end

      conditions = rule["conditions"]
      return action if conditions.nil?
      next unless conditions.is_a?(Hash)

      begin
        return action if @json_expr.evaluate_boolean_expr(conditions, attributes) == true
      rescue StandardError, SystemStackError
        next
      end
    end
    nil
  end

  private
    def parse_rule_action(rule)
      case rule["type"]
      when "assign"
        variant = rule["variant"]
        integer = variant.is_a?(Integer) || (variant.is_a?(Float) && variant.finite? && variant == variant.floor)
        integer ? RuleAction.new(variant.to_i, nil) : nil
      when "split"
        split = parse_split_percentages(rule["percentages"])
        split.nil? ? nil : RuleAction.new(nil, split)
      end
    end

    def parse_split_percentages(percentages)
      return nil unless percentages.is_a?(String)

      values = percentages.split("/", -1).map { |value| parse_float(value) }
      return nil if values.any? { |value| value.nil? || value.negative? }

      gap = (100 - values.sum).abs
      return nil unless gap.finite? && round_half_up(gap, 2) <= SPLIT_PERCENTAGES_SUM_TOLERANCE

      values.map { |value| value / 100 }
    end

    def parse_float(value)
      match = FLOAT_PREFIX.match(value)
      return nil if match.nil?

      text = match[1]
      return text.start_with?("-") ? -Float::INFINITY : Float::INFINITY if text.end_with?("Infinity")

      Float(text.sub(/\.(?=\z|[eE])/, ""))
    end

    # Like JavaScript's toFixed: rounds the exact binary value half up.
    def round_half_up(value, digits)
      value.to_r.round(digits, half: :up).to_f
    end
end

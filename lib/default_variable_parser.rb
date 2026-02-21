# frozen_string_literal: true

require_relative "variable_parser"

class DefaultVariableParser < VariableParser
  attr_accessor :reader, :log

  def parse(context, experiment_name, variant_name, config)
    JSON.parse(config, symbolize_names: true)
  rescue JSON::ParserError => e
    warn("Failed to parse variant config for experiment '#{experiment_name}', variant '#{variant_name}': #{e.message}")
    {}
  rescue StandardError => e
    warn("Unexpected error parsing variant config for experiment '#{experiment_name}': #{e.class} - #{e.message}")
    {}
  end
end

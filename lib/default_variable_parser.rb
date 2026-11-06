# frozen_string_literal: true

require_relative "variable_parser"

class DefaultVariableParser < VariableParser
  attr_accessor :reader, :log

  def parse(context, experiment_name, variant_name, config)
    JSON.parse(config, symbolize_names: true)
  rescue StandardError
    nil
  end
end

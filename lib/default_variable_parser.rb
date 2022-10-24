# frozen_string_literal: true

require_relative "variable_parser"

class DefaultVariableParser < VariableParser
  attr_accessor :reader, :log

  # def initialize(client)
  #   @client = client
  # end

  def parse(context, experiment_name, variant_name, config)
    @reader.read_value(config)
  end
end

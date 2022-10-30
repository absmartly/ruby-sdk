# frozen_string_literal: true

require "default_variable_parser"
require "context"
require "byebug"

RSpec.describe DefaultVariableParser do
  it ".parse" do
    context = instance_double(Context)
    config_value = resource("variables.json")

    variable_parser = described_class.new
    variables = variable_parser.parse(context, "test_exp", "B", config_value)

    expect(variables).to eq(
                           "a": 1,
                           "b": "test",
                           "c": {
                             "test": 2,
                             "double": 19.123,
                             "list": %w[x y z],
                             "point": {
                               "x": -1.0,
                               "y": 0.0,
                               "z": 1.0 } },
                           "d": true,
                           "f": [9234567890, "a", true, false],
                           "g": 9.123)
  end

  it ".parse does not throw" do
    context = instance_double(Context)
    config_value = resource("variables.json")[5..]

    variable_parser = described_class.new

    expect(variable_parser.parse(context, "test_exp", "B", config_value)).to be_nil
  end
end

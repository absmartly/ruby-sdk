# frozen_string_literal: true

require "a_b_smartly"
require "a_b_smartly_config"
require "context_data_provider"
require "context_event_handler"
require "variable_parser"
require "context_event_logger"
require "scheduled_executor_service"
require "client"

RSpec.describe ABSmartly do
  let(:client) { Client.new }

  it ".create" do
    config = ABSmartlyConfig.new
    config.client = client
    absmartly = described_class.create(config)
    expect(absmartly).not_to be_nil
  end
end

# frozen_string_literal: true

require "context_data_provider"
require "a_b_smartly_config"
require "context_event_handler"
require "variable_parser"
require "context_event_logger"
require "scheduled_executor_service"
require "client"

RSpec.describe ABSmartlyConfig do
  it ".context_data_provider" do
    provider = ContextDataProvider.new
    config = described_class.create
    config.context_data_provider = provider
    expect(provider).to eq(config.context_data_provider)
  end

  it ".context_event_handler" do
    handler = ContextEventHandler.new
    config = described_class.create
    config.context_event_handler = handler
    expect(handler).to eq(config.context_event_handler)
  end

  it ".variable_parser" do
    variable_parser = VariableParser.new
    config = described_class.create
    config.variable_parser = variable_parser
    expect(variable_parser).to eq(config.variable_parser)
  end

  it ".scheduler" do
    scheduler = VariableParser.new
    config = described_class.create
    config.scheduler = scheduler
    expect(scheduler).to eq(config.scheduler)
  end

  it ".context_event_logger" do
    logger = ContextEventLogger.new
    config = described_class.create
    config.context_event_logger = logger
    expect(logger).to eq(config.context_event_logger)
  end

  it "set all" do
    handler = ContextEventHandler.new
    provider = ContextDataProvider.new
    parser = VariableParser.new
    scheduler = ScheduledExecutorService.new
    client = instance_double(Client)
    config = described_class.create
    config.variable_parser = parser
    config.context_data_provider = provider
    config.context_event_handler = handler
    config.scheduler = scheduler
    config.client = client
    expect(provider).to eq(config.context_data_provider)
    expect(handler).to eq(config.context_event_handler)
    expect(parser).to eq(config.variable_parser)
    expect(scheduler).to eq(config.scheduler)
    expect(client).to eq(config.client)
  end
end

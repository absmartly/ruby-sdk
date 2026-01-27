# frozen_string_literal: true

require "context"
require "context_config"
require "default_context_data_deserializer"
require "default_variable_parser"
require "default_audience_deserializer"
require "context_data_provider"
require "default_context_data_provider"
require "context_event_handler"
require "context_event_logger"
require "audience_matcher"
require "json/unit"
require "logger"

RSpec.describe "Concurrent Operations" do
  let(:units) {
    {
      session_id: "e791e240fcd3df7d238cfc285f475e8152fcc0ec",
      user_id: "123456789",
      email: "bleh@absmartly.com"
    }
  }
  let(:clock) { Time.at(1620000000000 / 1000) }

  let(:descr) { DefaultContextDataDeserializer.new }
  let(:json) { resource("context.json") }
  let(:data) { descr.deserialize(json, 0, json.length) }

  let(:publish_future) { OpenStruct.new(success?: true) }
  let(:event_handler) do
    ev = instance_double(ContextEventHandler)
    allow(ev).to receive(:publish).and_return(publish_future)
    ev
  end
  let(:event_logger) { nil }
  let(:variable_parser) { DefaultVariableParser.new }
  let(:audience_matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }

  def client_mock(data_future = nil)
    client = instance_double(Client)
    allow(client).to receive(:context_data).and_return(OpenStruct.new(data_future: data_future || data, success?: true))
    client
  end

  let(:data_provider) { DefaultContextDataProvider.new(client_mock) }
  let(:data_future_ready) { data_provider.context_data }

  def create_context
    config = ContextConfig.create
    config.set_units(units)

    Context.create(clock, config, data_future_ready, data_provider,
                   event_handler, event_logger, variable_parser, audience_matcher)
  end

  describe "thread-safe treatment access" do
    it "handles concurrent getTreatment calls without errors" do
      context = create_context
      errors = []
      results = []
      mutex = Mutex.new

      threads = 10.times.map do
        Thread.new do
          20.times do
            begin
              result = context.treatment("exp_test_ab")
              mutex.synchronize { results << result }
            rescue StandardError => e
              mutex.synchronize { errors << e }
            end
          end
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty
      expect(results.uniq.length).to eq(1)
      expect(results.first).to be_a(Integer)
    end

    it "returns consistent treatment values across threads" do
      context = create_context
      treatments = []
      mutex = Mutex.new

      threads = 5.times.map do
        Thread.new do
          10.times do
            treatment = context.treatment("exp_test_ab")
            mutex.synchronize { treatments << treatment }
          end
        end
      end

      threads.each(&:join)

      expect(treatments.uniq.length).to eq(1)
    end
  end

  describe "thread-safe goal tracking" do
    it "handles concurrent track calls without errors" do
      context = create_context
      errors = []
      mutex = Mutex.new

      threads = 10.times.map do |i|
        Thread.new do
          10.times do |j|
            begin
              context.track("goal_#{i}_#{j}", { value: i * j })
            rescue StandardError => e
              mutex.synchronize { errors << e }
            end
          end
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty
      expect(context.pending_count).to eq(100)
    end

    it "tracks all goals from concurrent threads" do
      context = create_context
      tracked_count = 0
      mutex = Mutex.new

      threads = 5.times.map do
        Thread.new do
          10.times do
            context.track("concurrent_goal", { amount: 1 })
            mutex.synchronize { tracked_count += 1 }
          end
        end
      end

      threads.each(&:join)

      expect(tracked_count).to eq(50)
      expect(context.pending_count).to eq(50)
    end
  end

  describe "thread-safe publishing" do
    it "handles concurrent publish requests safely" do
      context = create_context

      50.times { context.track("goal", nil) }

      publish_count = Concurrent::AtomicFixnum.new(0) rescue 0
      mutex = Mutex.new
      errors = []

      threads = 5.times.map do
        Thread.new do
          begin
            context.publish
            if defined?(Concurrent::AtomicFixnum)
              publish_count.increment
            else
              mutex.synchronize { publish_count += 1 }
            end
          rescue StandardError => e
            mutex.synchronize { errors << e }
          end
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty
    end

    it "does not lose events during concurrent operations" do
      context = create_context

      threads = 5.times.map do |i|
        Thread.new do
          5.times do |j|
            context.track("goal_#{i}_#{j}", nil)
            context.treatment("exp_test_ab") if j.even?
          end
        end
      end

      threads.each(&:join)

      expect(context.pending_count).to be >= 25
    end
  end

  describe "thread-safe attribute setting" do
    it "handles concurrent set_attribute calls" do
      context = create_context
      errors = []
      mutex = Mutex.new

      threads = 10.times.map do |i|
        Thread.new do
          10.times do |j|
            begin
              context.set_attribute("attr_#{i}_#{j}", "value_#{i}_#{j}")
            rescue StandardError => e
              mutex.synchronize { errors << e }
            end
          end
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty
      attrs = context.instance_variable_get(:@attributes)
      expect(attrs.length).to eq(100)
    end
  end

  describe "thread-safe context creation" do
    it "creates multiple contexts concurrently without errors" do
      contexts = []
      errors = []
      mutex = Mutex.new

      threads = 10.times.map do
        Thread.new do
          begin
            ctx = create_context
            mutex.synchronize { contexts << ctx }
          rescue StandardError => e
            mutex.synchronize { errors << e }
          end
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty
      expect(contexts.length).to eq(10)
      contexts.each do |ctx|
        expect(ctx.ready?).to be_truthy
      end
    end
  end
end

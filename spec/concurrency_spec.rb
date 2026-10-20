# frozen_string_literal: true

require "ostruct"
require "timeout"
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

      publish_results = []
      mutex = Mutex.new
      errors = []

      threads = 5.times.map do
        Thread.new do
          begin
            result = context.publish
            mutex.synchronize { publish_results << result }
          rescue StandardError => e
            mutex.synchronize { errors << e }
          end
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty
    end

    it "includes each queued event in at most one publish" do
      sent = []
      sent_mutex = Mutex.new
      handler = instance_double(ContextEventHandler)
      allow(handler).to receive(:publish) do |_ctx, event|
        sleep 0.02
        sent_mutex.synchronize { sent.concat((event.goals || []).map(&:name)) }
        publish_future
      end
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(clock, config, data_future_ready, data_provider,
                               handler, event_logger, variable_parser, audience_matcher)

      20.times { |i| context.track("goal_#{i}", nil) }
      5.times.map { Thread.new { context.publish } }.each(&:join)

      expect(sent.sort).to eq(sent.uniq.sort)
      expect(sent.size).to eq(20)
    end

    it "allows event logger callbacks to call track and publish" do
      logger = Class.new do
        attr_accessor :context
        def handle_event(event, _data)
          return unless event == ContextEventLogger::EVENT_TYPE::EXPOSURE
          context.track("from_callback", nil)
          context.publish
        end
      end.new
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(clock, config, data_future_ready, data_provider,
                               event_handler, logger, variable_parser, audience_matcher)
      logger.context = context

      expect { context.treatment("exp_test_ab") }.not_to raise_error
    end

    it "allows a PUBLISH callback to call publish without deadlocking" do
      logger = Class.new do
        attr_accessor :context
        def handle_event(event, _data)
          context.publish if event == ContextEventLogger::EVENT_TYPE::PUBLISH
        end
      end.new
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(clock, config, data_future_ready, data_provider,
                               event_handler, logger, variable_parser, audience_matcher)
      logger.context = context
      context.track("goal", nil)

      expect { Timeout.timeout(5) { context.publish } }.not_to raise_error
      expect(event_handler).to have_received(:publish).once
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

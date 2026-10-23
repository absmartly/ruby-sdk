# frozen_string_literal: true

require "a_b_smartly"
require "a_b_smartly_config"
require "client"
require "context_config"

RSpec.describe ABSmartly do
  describe ".new with named parameters" do
    let(:valid_params) do
      {
        endpoint: "https://test.absmartly.io/v1",
        api_key: "test-api-key",
        application: "website",
        environment: "development"
      }
    end

    context "with all required parameters" do
      it "creates an instance successfully" do
        sdk = ABSmartly.new(
          valid_params[:endpoint],
          api_key: valid_params[:api_key],
          application: valid_params[:application],
          environment: valid_params[:environment]
        )

        expect(sdk).not_to be_nil
        expect(sdk.client).not_to be_nil
        expect(sdk.context_data_provider).not_to be_nil
        expect(sdk.context_event_handler).not_to be_nil
        expect(sdk.variable_parser).not_to be_nil
        expect(sdk.audience_deserializer).not_to be_nil
        expect(sdk.scheduler).not_to be_nil
      end

      it "uses default timeout of 3000ms" do
        sdk = ABSmartly.new(
          valid_params[:endpoint],
          api_key: valid_params[:api_key],
          application: valid_params[:application],
          environment: valid_params[:environment]
        )

        expect(sdk).not_to be_nil
      end

      it "uses default retries of 5" do
        sdk = ABSmartly.new(
          valid_params[:endpoint],
          api_key: valid_params[:api_key],
          application: valid_params[:application],
          environment: valid_params[:environment]
        )

        expect(sdk).not_to be_nil
      end
    end

    context "with optional timeout parameter" do
      it "creates an instance with custom timeout" do
        sdk = ABSmartly.new(
          valid_params[:endpoint],
          api_key: valid_params[:api_key],
          application: valid_params[:application],
          environment: valid_params[:environment],
          timeout: 5000
        )

        expect(sdk).not_to be_nil
      end

      it "rejects negative timeout" do
        expect {
          ABSmartly.new(
            valid_params[:endpoint],
            api_key: valid_params[:api_key],
            application: valid_params[:application],
            environment: valid_params[:environment],
            timeout: -1000
          )
        }.to raise_error(ArgumentError, "timeout must be a positive number")
      end

      it "rejects zero timeout" do
        expect {
          ABSmartly.new(
            valid_params[:endpoint],
            api_key: valid_params[:api_key],
            application: valid_params[:application],
            environment: valid_params[:environment],
            timeout: 0
          )
        }.to raise_error(ArgumentError, "timeout must be a positive number")
      end
    end

    context "with optional retries parameter" do
      it "creates an instance with custom retries" do
        sdk = ABSmartly.new(
          valid_params[:endpoint],
          api_key: valid_params[:api_key],
          application: valid_params[:application],
          environment: valid_params[:environment],
          retries: 3
        )

        expect(sdk).not_to be_nil
      end

      it "accepts zero retries" do
        sdk = ABSmartly.new(
          valid_params[:endpoint],
          api_key: valid_params[:api_key],
          application: valid_params[:application],
          environment: valid_params[:environment],
          retries: 0
        )

        expect(sdk).not_to be_nil
      end

      it "rejects negative retries" do
        expect {
          ABSmartly.new(
            valid_params[:endpoint],
            api_key: valid_params[:api_key],
            application: valid_params[:application],
            environment: valid_params[:environment],
            retries: -1
          )
        }.to raise_error(ArgumentError, "retries must be a non-negative number")
      end
    end

    context "with context_event_logger parameter" do
      let(:mock_logger) { double("event_logger") }

      it "sets the event logger" do
        sdk = ABSmartly.new(
          valid_params[:endpoint],
          api_key: valid_params[:api_key],
          application: valid_params[:application],
          environment: valid_params[:environment],
          context_event_logger: mock_logger
        )

        expect(sdk.context_event_logger).to eq(mock_logger)
      end
    end

    context "with all optional parameters" do
      let(:mock_logger) { double("event_logger") }

      it "creates an instance successfully" do
        sdk = ABSmartly.new(
          valid_params[:endpoint],
          api_key: valid_params[:api_key],
          application: valid_params[:application],
          environment: valid_params[:environment],
          timeout: 5000,
          retries: 3,
          context_event_logger: mock_logger
        )

        expect(sdk).not_to be_nil
        expect(sdk.context_event_logger).to eq(mock_logger)
      end
    end

    context "with missing required parameters" do
      it "raises error when endpoint is missing" do
        expect {
          ABSmartly.new(
            nil,
            api_key: valid_params[:api_key],
            application: valid_params[:application],
            environment: valid_params[:environment]
          )
        }.to raise_error(ArgumentError, "Missing required parameter: endpoint")
      end

      it "raises error when endpoint is empty" do
        expect {
          ABSmartly.new(
            "  ",
            api_key: valid_params[:api_key],
            application: valid_params[:application],
            environment: valid_params[:environment]
          )
        }.to raise_error(ArgumentError, "Missing required parameter: endpoint")
      end

      it "raises error when api_key is missing" do
        expect {
          ABSmartly.new(
            valid_params[:endpoint],
            api_key: nil,
            application: valid_params[:application],
            environment: valid_params[:environment]
          )
        }.to raise_error(ArgumentError, "Missing required parameter: api_key")
      end

      it "raises error when api_key is empty" do
        expect {
          ABSmartly.new(
            valid_params[:endpoint],
            api_key: "",
            application: valid_params[:application],
            environment: valid_params[:environment]
          )
        }.to raise_error(ArgumentError, "Missing required parameter: api_key")
      end

      it "raises error when application is missing" do
        expect {
          ABSmartly.new(
            valid_params[:endpoint],
            api_key: valid_params[:api_key],
            application: nil,
            environment: valid_params[:environment]
          )
        }.to raise_error(ArgumentError, "Missing required parameter: application")
      end

      it "raises error when application is empty" do
        expect {
          ABSmartly.new(
            valid_params[:endpoint],
            api_key: valid_params[:api_key],
            application: "",
            environment: valid_params[:environment]
          )
        }.to raise_error(ArgumentError, "Missing required parameter: application")
      end

      it "raises error when environment is missing" do
        expect {
          ABSmartly.new(
            valid_params[:endpoint],
            api_key: valid_params[:api_key],
            application: valid_params[:application],
            environment: nil
          )
        }.to raise_error(ArgumentError, "Missing required parameter: environment")
      end

      it "raises error when environment is empty" do
        expect {
          ABSmartly.new(
            valid_params[:endpoint],
            api_key: valid_params[:api_key],
            application: valid_params[:application],
            environment: ""
          )
        }.to raise_error(ArgumentError, "Missing required parameter: environment")
      end
    end

    context "backwards compatibility with ABSmartlyConfig" do
      let(:client) { instance_double(Client) }

      it "still works with ABSmartlyConfig.create approach" do
        config = ABSmartlyConfig.create
        config.client = client

        sdk = ABSmartly.new(config)

        expect(sdk).not_to be_nil
        expect(sdk.client).to eq(client)
      end

      it "works with ABSmartly.create(config)" do
        config = ABSmartlyConfig.create
        config.client = client

        sdk = ABSmartly.create(config)

        expect(sdk).not_to be_nil
        expect(sdk.client).to eq(client)
      end
    end
  end
end

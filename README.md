# ABsmartly Ruby SDK

Ruby SDK for [ABsmartly](https://www.absmartly.com/) A/B testing platform.

## Compatibility

The ABsmartly Ruby SDK is compatible with Ruby versions 2.7 and later. For the best performance and code readability, Ruby 3 or later is recommended. This SDK is being constantly tested with the nightly builds of Ruby, to ensure it is compatible with the latest Ruby version.

## Getting Started

### Install the SDK

Install the gem and add to the application's Gemfile by executing:

```bash
$ bundle add absmartly-sdk
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
$ gem install absmartly-sdk
```

### Import and Initialize the SDK

#### Recommended: Named Parameters (Ruby Keyword Arguments)

The simplest and most idiomatic way to initialize the SDK in Ruby:

```ruby
require 'absmartly'

sdk = ABSmartly.new(
  "https://your-company.absmartly.io/v1",
  api_key: "YOUR-API-KEY",
  application: "website",
  environment: "development"
)
```

With optional parameters for timeout and retries:

```ruby
sdk = ABSmartly.new(
  "https://your-company.absmartly.io/v1",
  api_key: "YOUR-API-KEY",
  application: "website",
  environment: "development",
  timeout: 5000,      # Connection timeout in milliseconds (default: 3000)
  retries: 3          # Max retry attempts (default: 5)
)
```

With a custom event logger:

```ruby
sdk = ABSmartly.new(
  "https://your-company.absmartly.io/v1",
  api_key: "YOUR-API-KEY",
  application: "website",
  environment: "development",
  context_event_logger: CustomEventLogger.new
)
```

#### Alternative: Global Configuration

For applications that need a single SDK instance shared globally:

```ruby
require 'absmartly'

Absmartly.configure_client do |config|
  config.endpoint = "https://your-company.absmartly.io/v1"
  config.api_key = "YOUR-API-KEY"
  config.application = "website"
  config.environment = "development"
end
```

#### Advanced: Full Configuration with Builder Pattern

For advanced use cases where you need custom providers, serializers, or other low-level configurations:

```ruby
require 'absmartly'

client_config = ClientConfig.create
client_config.endpoint = "https://your-company.absmartly.io/v1"
client_config.api_key = "YOUR-API-KEY"
client_config.application = "website"
client_config.environment = "development"
client_config.connect_timeout = 3.0
client_config.connection_request_timeout = 3.0
client_config.retry_interval = 0.5
client_config.max_retries = 5

sdk_config = ABSmartlyConfig.create
sdk_config.client = Client.create(client_config)

sdk = ABSmartly.create(sdk_config)
```

**SDK Options**

| Parameter                  | Type                              | Required? | Default | Description                                                                                                                                                                   |
| :------------------------- | :-------------------------------- | :-------: | :-----: | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| endpoint                   | `String`                          |  &#9989;  | `nil`   | The URL to your API endpoint. Most commonly `"https://your-company.absmartly.io/v1"` (first positional parameter)                                                            |
| api_key                    | `String`                          |  &#9989;  | `nil`   | Your API key which can be found on the Web Console.                                                                                                                           |
| application                | `String`                          |  &#9989;  | `nil`   | The name of the application where the SDK is installed. Applications are created on the Web Console and should match the applications where your experiments will be running. |
| environment                | `String`                          |  &#9989;  | `nil`   | The environment of the platform where the SDK is installed. Environments are created on the Web Console and should match the available environments in your infrastructure.   |
| timeout                    | `Integer`                         |  &#10060; | `3000`  | The connection and request timeout in milliseconds. Converted to seconds internally.                                                                                          |
| retries                    | `Integer`                         |  &#10060; | `5`     | The maximum number of retries before giving up.                                                                                                                               |
| context_event_logger       | `ContextEventLogger`              |  &#10060; | `nil`   | A `ContextEventLogger` instance implementing `handle_event(event, data)` to receive SDK events. See "Using a Custom Event Logger" below.                                     |

### Using a Custom Event Logger

The ABsmartly SDK can be instantiated with an event logger used for all contexts. In addition, an event logger can be specified when creating a particular context in the context config.

```ruby
class CustomEventLogger < ContextEventLogger
  def handle_event(event, data)
    case event
    when EVENT_TYPE::EXPOSURE
      puts "Exposed to experiment: #{data[:name]}"
    when EVENT_TYPE::GOAL
      puts "Goal tracked: #{data[:name]}"
    when EVENT_TYPE::ERROR
      puts "Error: #{data}"
    when EVENT_TYPE::PUBLISH
      puts "Events published: #{data.length} events"
    when EVENT_TYPE::READY
      puts "Context ready with #{data[:experiments].length} experiments"
    when EVENT_TYPE::REFRESH
      puts "Context refreshed with #{data[:experiments].length} experiments"
    when EVENT_TYPE::CLOSE
      puts "Context closed"
    end
  end
end

sdk = ABSmartly.new(
  "https://your-company.absmartly.io/v1",
  api_key: "YOUR-API-KEY",
  application: "website",
  environment: "development",
  context_event_logger: CustomEventLogger.new
)
```

Or using the global configuration approach:

```ruby
Absmartly.configure_client do |config|
  config.endpoint = "https://your-company.absmartly.io/v1"
  config.api_key = "YOUR-API-KEY"
  config.application = "website"
  config.environment = "development"
  config.event_logger = CustomEventLogger.new
end
```

The data parameter depends on the type of event. Currently, the SDK logs the following events:

**Event Types**

| Event       | When                                                    | Data                                         |
| ----------- | ------------------------------------------------------- | -------------------------------------------- |
| `Error`     | `Context` receives an error                             | Error object thrown                          |
| `Ready`     | `Context` turns ready                                   | ContextData used to initialize the context   |
| `Refresh`   | `Context.refresh()` method succeeds                     | ContextData used to refresh the context      |
| `Publish`   | `Context.publish()` method succeeds                     | PublishEvent sent to the collector           |
| `Exposure`  | `Context.treatment()` method succeeds on first exposure | Exposure data enqueued for publishing        |
| `Goal`      | `Context.track()` method succeeds                       | GoalAchievement enqueued for publishing      |
| `Close`     | `Context.close()` method succeeds the first time        | `nil`                                        |

## Create a New Context Request

### Basic Context Creation

```ruby
sdk = ABSmartly.new(
  "https://your-company.absmartly.io/v1",
  api_key: "YOUR-API-KEY",
  application: "website",
  environment: "development"
)

context_config = ContextConfig.create
context_config.set_unit('session_id', '5ebf06d8cb5d8137290c4abb64155584fbdb64d8')

context = sdk.create_context(context_config)
context.wait_until_ready
```

Or using the global configuration approach:

```ruby
Absmartly.configure_client do |config|
  config.endpoint = "https://your-company.absmartly.io/v1"
  config.api_key = "YOUR-API-KEY"
  config.application = "website"
  config.environment = "development"
end

context_config = Absmartly.create_context_config
context_config.set_unit('session_id', '5ebf06d8cb5d8137290c4abb64155584fbdb64d8')

context = Absmartly.create_context(context_config)
context.wait_until_ready
```

### With Prefetched Data

When doing full-stack experimentation with ABsmartly, we recommend creating a context only once on the server-side. Creating a context involves a round-trip to the ABsmartly event collector. We can avoid repeating the round-trip on the client-side by sending the server-side data embedded in the first document.

```ruby
# Server-side
sdk = ABSmartly.new(
  "https://your-company.absmartly.io/v1",
  api_key: "YOUR-API-KEY",
  application: "website",
  environment: "development"
)

context_config = ContextConfig.create
context_config.set_unit('session_id', '5ebf06d8cb5d8137290c4abb64155584fbdb64d8')

server_context = sdk.create_context(context_config)
server_context.wait_until_ready

# Pass server_context.data to client-side

# Client-side - reuse the data
client_context_config = ContextConfig.create
client_context_config.set_unit('session_id', '5ebf06d8cb5d8137290c4abb64155584fbdb64d8')

client_context = sdk.create_context_with(client_context_config, server_context.data)
# No need to wait - context is ready immediately
```

### Refreshing the Context with Fresh Experiment Data

For long-running contexts, the context is usually created once when the application is first started. However, any experiments being tracked in your production code, but started after the context was created, will not be triggered.

The `refresh` method can be called manually. The `refresh` method pulls updated experiment data from the ABsmartly collector and will trigger recently started experiments when `treatment` is called again.

```ruby
context.refresh
```

### Setting Extra Units

You can add additional units to a context by calling the `set_unit` or `set_units` methods. These methods may be used, for example, when a user logs in to your application and you want to use the new unit type in the context.

> **Note:** You cannot override an already set unit type as that would be a change of identity and would throw an exception. In this case, you must create a new context instead. The `set_unit` and `set_units` methods can be called before the context is ready.

```ruby
context_config.set_unit('session_id', 'bf06d8cb5d8137290c4abb64155584fbdb64d8')
context_config.set_unit('user_id', '123456')
context = Absmartly.create_context(context_config)
```

or

```ruby
context_config.set_units(
  session_id: 'bf06d8cb5d8137290c4abb64155584fbdb64d8',
  user_id: '123456'
)
context = Absmartly.create_context(context_config)
```

## Basic Usage

### Selecting a Treatment

```ruby
treatment = context.treatment('exp_test_experiment')

if treatment.zero?
  # user is in control group (variant 0)
else
  # user is in treatment group
end
```

### Treatment Variables

Variables allow you to configure experiment variants dynamically:

```ruby
default_button_color = 'red'
button_color = context.variable_value('button.color', default_button_color)
```

### Peek at Treatment Variants

Although generally not recommended, it is sometimes necessary to peek at a treatment or variable without triggering an exposure. The ABsmartly SDK provides `peek_treatment` and `peek_variable_value` methods for that.

```ruby
treatment = context.peek_treatment('exp_test_experiment')
```

#### Peeking at Variables

```ruby
button_color = context.peek_variable_value('button.color', 'red')
```

### Overriding Treatment Variants

During development, for example, it is useful to force a treatment for an experiment. This can be achieved with the `set_override` and/or `set_overrides` methods. These methods can be called before the context is ready.

```ruby
context.set_override('exp_test_experiment', 1) # force variant 1 of treatment

context.set_overrides(
  'exp_test_experiment' => 1,
  'exp_another_experiment' => 0
)
```

## Advanced

### Context Attributes

Attributes are used to pass meta-data about the user and/or the request. They can be used later in the Web Console to create segments or audiences. They can be set using the `set_attribute` or `set_attributes` methods, before or after the context is ready.

```ruby
context.set_attribute('user_agent', request.user_agent)

context.set_attributes(
  customer_age: 'new_customer',
  account_type: 'premium'
)
```

### Custom Assignments

Sometimes it may be necessary to override the automatic selection of a variant. For example, if you wish to have your variant chosen based on data from an API call. This can be accomplished using the `set_custom_assignment` method.

```ruby
chosen_variant = 1
context.set_custom_assignment('experiment_name', chosen_variant)
```

If you are running multiple experiments and need to choose different custom assignments for each one, you can do so using the `set_custom_assignments` method.

```ruby
assignments = {
  'experiment_name' => 1,
  'another_experiment_name' => 0,
  'a_third_experiment_name' => 2
}

context.set_custom_assignments(assignments)
```

### Tracking Goals

Goals are created in the ABsmartly web console.

```ruby
context.track('payment', {
  item_count: 1,
  total_amount: 1999.99
})
```

### Publish

Sometimes it is necessary to ensure all events have been published to the ABsmartly collector, before proceeding. You can explicitly call the `publish` method.

```ruby
context.publish
```

### Finalize

The `close` method will ensure all events have been published to the ABsmartly collector, like `publish`, and will also "seal" the context, throwing an error if any method that could generate an event is called.

```ruby
context.close
```

## Platform-Specific Examples

### Using with Ruby on Rails

```ruby
# config/initializers/absmartly.rb
require 'absmartly'

Absmartly.configure_client do |config|
  config.endpoint = ENV['ABSMARTLY_ENDPOINT']
  config.api_key = ENV['ABSMARTLY_API_KEY']
  config.application = "website"
  config.environment = Rails.env
end

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  before_action :setup_absmartly_context
  after_action :close_absmartly_context

  private

  def setup_absmartly_context
    context_config = Absmartly.create_context_config
    context_config.set_unit('session_id', session.id.to_s)
    context_config.set_unit('user_id', current_user&.id&.to_s) if current_user

    @absmartly_context = Absmartly.create_context(context_config)
    @absmartly_context.wait_until_ready
  rescue => e
    Rails.logger.error "ABsmartly context creation failed: #{e.message}"
    @absmartly_context = nil
  end

  def close_absmartly_context
    @absmartly_context&.close
  end
end

# app/controllers/products_controller.rb
class ProductsController < ApplicationController
  def show
    treatment = @absmartly_context&.treatment('exp_product_layout') || 0

    if treatment == 0
      render 'show_control'
    else
      render 'show_treatment'
    end
  end
end
```

### Using with Sinatra

```ruby
require 'sinatra'
require 'absmartly'

# Initialize SDK once at app startup
configure do
  Absmartly.configure_client do |config|
    config.endpoint = ENV['ABSMARTLY_ENDPOINT']
    config.api_key = ENV['ABSMARTLY_API_KEY']
    config.application = "website"
    config.environment = ENV['RACK_ENV']
  end
end

# Middleware to create context for each request
use Rack::Session::Cookie, secret: ENV['SESSION_SECRET']

before do
  context_config = Absmartly.create_context_config
  context_config.set_unit('session_id', session[:session_id] ||= SecureRandom.uuid)

  @absmartly_context = Absmartly.create_context(context_config)
  @absmartly_context.wait_until_ready
end

after do
  @absmartly_context&.close
end

get '/' do
  treatment = @absmartly_context.treatment('exp_test_experiment')

  if treatment == 0
    erb :control
  else
    erb :treatment
  end
end
```

### Using with Rack Middleware

```ruby
# config.ru
require 'absmartly'

class ABsmartlyMiddleware
  def initialize(app)
    @app = app

    Absmartly.configure_client do |config|
      config.endpoint = ENV['ABSMARTLY_ENDPOINT']
      config.api_key = ENV['ABSMARTLY_API_KEY']
      config.application = "website"
      config.environment = ENV['RACK_ENV']
    end
  end

  def call(env)
    request = Rack::Request.new(env)

    context_config = Absmartly.create_context_config
    context_config.set_unit('session_id', request.session['session_id'])

    context = Absmartly.create_context(context_config)
    context.wait_until_ready

    env['absmartly.context'] = context

    status, headers, body = @app.call(env)

    context.close

    [status, headers, body]
  end
end

use ABsmartlyMiddleware
run MyApp
```

## Advanced Request Configuration

### Request Timeout Override

Ruby HTTP clients support per-request timeouts:

```ruby
require 'absmartly'
require 'timeout'

context_config = Absmartly.create_context_config
context_config.set_unit('session_id', 'abc123')

ctx = Absmartly.create_context(context_config)

begin
  Timeout.timeout(1.5) do
    ctx.wait_until_ready
  end
rescue Timeout::Error
  puts "Context creation timed out"
end
```

### Request Cancellation with Thread

```ruby
require 'absmartly'

context_config = Absmartly.create_context_config
context_config.set_unit('session_id', 'abc123')

ctx = Absmartly.create_context(context_config)

# Create thread for context initialization
thread = Thread.new do
  ctx.wait_until_ready
end

# Cancel after 1.5 seconds if not ready
sleep 1.5
if thread.alive?
  thread.kill
  puts "Context creation cancelled"
end
```

## About A/B Smartly

**A/B Smartly** is the leading provider of state-of-the-art, on-premises, full-stack experimentation platforms for engineering and product teams that want to confidently deploy features as fast as they can develop them.
A/B Smartly's real-time analytics helps engineering and product teams ensure that new features will improve the customer experience without breaking or degrading performance and/or business metrics.

### Have a look at our growing list of clients and SDKs:
- [JavaScript SDK](https://www.github.com/absmartly/javascript-sdk)
- [Java SDK](https://www.github.com/absmartly/java-sdk)
- [PHP SDK](https://www.github.com/absmartly/php-sdk)
- [Swift SDK](https://www.github.com/absmartly/swift-sdk)
- [Vue2 SDK](https://www.github.com/absmartly/vue2-sdk)
- [Vue3 SDK](https://www.github.com/absmartly/vue3-sdk)
- [React SDK](https://www.github.com/absmartly/react-sdk)
- [Python3 SDK](https://www.github.com/absmartly/python3-sdk)
- [Go SDK](https://www.github.com/absmartly/go-sdk)
- [Ruby SDK](https://www.github.com/absmartly/ruby-sdk) (this package)
- [.NET SDK](https://www.github.com/absmartly/dotnet-sdk)
- [Dart SDK](https://www.github.com/absmartly/dart-sdk)
- [Flutter SDK](https://www.github.com/absmartly/flutter-sdk)

## Documentation

- [Full Documentation](https://docs.absmartly.com/)

## License

MIT License - see LICENSE for details.

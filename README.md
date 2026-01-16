# A/B Smartly SDK

A/B Smartly Ruby SDK

## Compatibility

The A/B Smartly Ruby SDK is compatible with Ruby versions 2.7 and later.  For the best performance and code readability, Ruby 3 or later is recommended. This SDK is being constantly tested with the nightly builds of Ruby, to ensure it is compatible with the latest Ruby version.


## Getting Started

### Install the SDK

Install the gem and add to the application's Gemfile by executing:

    $ bundle add absmartly-sdk

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install absmartly-sdk

## Import and Initialize the SDK

Once the SDK is installed, it can be initialized in your project.

```ruby
Absmartly.configure_client do |config|
  config.endpoint = "https://your-company.absmartly.io/v1"
  config.api_key = "YOUR-API-KEY"
  config.application = "website"
  config.environment = "development"
  config.connect_timeout = 3.0
  config.connection_request_timeout = 3.0
  config.retry_interval = 0.5
  config.max_retries = 5
end
```

**SDK Options**

| Config      | Type                                 | Required? |                 Default                 | Description                                                                                                                                                                   |
| :---------- | :----------------------------------- | :-------: | :-------------------------------------: | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| endpoint    | `string`                             |  &#9989;  |               `undefined`               | The URL to your API endpoint. Most commonly `"your-company.absmartly.io"`                                                                                                     |
| api_key      | `string`                             |  &#9989;  |               `undefined`               | Your API key which can be found on the Web Console.                                                                                                                           |
| environment | `"production"` or `"development"`    |  &#9989;  |               `undefined`               | The environment of the platform where the SDK is installed. Environments are created on the Web Console and should match the available environments in your infrastructure.   |
| application | `string`                             |  &#9989;  |               `undefined`               | The name of the application where the SDK is installed. Applications are created on the Web Console and should match the applications where your experiments will be running. |
| connect_timeout     | `number`                             | &#10060;  |                   `3.0`                   | The socket connection timeout in seconds.                                                                                                                 |
| connection_request_timeout     | `number`                             | &#10060;  |                 `3.0`                  | The request timeout in seconds.                                                                                               |
| retry_interval     | `number`                             | &#10060;  |                   `0.5`                   | The initial retry interval in seconds (uses exponential backoff).                                                                                                                 |
| max_retries     | `number`                             | &#10060;  |                 `5`                  | The maximum number of retries before giving up.                                                                                               |
| eventLogger | `(context, eventName, data) => void` | &#10060;  | See "Using a Custom Event Logger" below | A callback function which runs after SDK events.                                                                                                                              |

### Using a Custom Event Logger

The A/B Smartly SDK can be instantiated with an event logger used for all
contexts. In addition, an event logger can be specified when creating a
particular context in the context config.

```ruby
class MyEventLogger < ContextEventLogger
  def handle_event(event, data)
    case event
    when EVENT_TYPE::EXPOSURE
      puts "Exposure: #{data}"
    when EVENT_TYPE::GOAL
      puts "Goal: #{data}"
    when EVENT_TYPE::ERROR
      puts "Error: #{data}"
    when EVENT_TYPE::PUBLISH
      puts "Publish: #{data}"
    when EVENT_TYPE::READY
      puts "Ready: #{data}"
    when EVENT_TYPE::REFRESH
      puts "Refresh: #{data}"
    when EVENT_TYPE::CLOSE
      puts "Close"
    end
  end
end

Absmartly.configure_client do |config|
  config.endpoint = "https://your-company.absmartly.io/v1"
  config.api_key = "YOUR-API-KEY"
  config.application = "website"
  config.environment = "development"
  config.event_logger = MyEventLogger.new
end
```

The data parameter depends on the type of event. Currently, the SDK logs the
following events:

| eventName    | when                                                    | data                                         |
| ------------ | ------------------------------------------------------- | -------------------------------------------- |
| `"error"`    | `Context` receives an error                             | error object thrown                          |
| `"ready"`    | `Context` turns ready                                   | data used to initialize the context          |
| `"refresh"`  | `Context.refresh()` method succeeds                     | data used to refresh the context             |
| `"publish"`  | `Context.publish()` method succeeds                     | data sent to the A/B Smartly event collector |
| `"exposure"` | `Context.treatment()` method succeeds on first exposure | exposure data enqueued for publishing        |
| `"goal"`     | `Context.track()` method succeeds                       | goal data enqueued for publishing            |
| `"close"` | `Context.close()` method succeeds the first time     | nil                                    |

## Create a New Context Request


```ruby
context_config = Absmartly.create_context_config
```

**With Prefetched Data**

```ruby
client_config = ClientConfig.new(
  endpoint: 'https://your-company.absmartly.io/v1',
  api_key: 'YOUR-API-KEY',
  application: 'website',
  environment: 'development')

sdk_config = ABSmartlyConfig.create
sdk_config.client = Client.create(client_config)

sdk = Absmartly.create(sdk_config)
```

**Refreshing the Context with Fresh Experiment Data**

For long-running contexts, the context is usually created once when the
application is first started. However, any experiments being tracked in your
production code, but started after the context was created, will not be
triggered.

Alternatively, the `refresh` method can be called manually. The
`refresh` method pulls updated experiment data from the A/B
Smartly collector and will trigger recently started experiments when
`treatment` is called again.

**Setting Extra Units**

You can add additional units to a context by calling the `set_unit()` or
`set_units()` methods. These methods may be used, for example, when a user
logs in to your application and you want to use the new unit type in the
context.

Please note, you cannot override an already set unit type as that would be
a change of identity and would throw an exception. In this case, you must
create a new context instead. The `set_unit()` and
`set_units()` methods can be called before the context is ready.

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

### Selecting A Treatment

```ruby
treatment = context.treatment('exp_test_experiment')

if treatment.zero?
  # user is in control group (variant 0)
else
  # user is in treatment group
end
```

### Treatment Variables

```ruby
default_button_color_value = 'red'

context.variable_value('experiment_name', default_button_color_value)
```

### Peek at Treatment Variants

Although generally not recommended, it is sometimes necessary to peek at
a treatment or variable without triggering an exposure. The A/B Smartly
SDK provides a `peek_treatment()` method for that.

```ruby
treatment = context.peek_treatment('exp_test_experiment')
```

#### Peeking at variables

```ruby
treatment = context.peek_variable_value('exp_test_experiment')
```

### Overriding Treatment Variants

During development, for example, it is useful to force a treatment for an
experiment. This can be achieved with the `set_override()` and/or `set_overrides()`
methods. These methods can be called before the context is ready.

```ruby
context.set_override("exp_test_experiment", 1) # force variant 1 of treatment

context.set_overrides(
    'exp_test_experiment' => 1,
    'exp_another_experiment' => 0,
)
```

## Advanced

### Context Attributes

Attributes are used to pass meta-data about the user and/or the request.
They can be used later in the Web Console to create segments or audiences.
They can be set using the `set_attribute()` or `set_attributes()`
methods, before or after the context is ready.

```ruby
context.set_attribute('session_id', session_id)
context.set_attributes(
    'customer_age' => 'new_customer'
)
```

### Custom Assignments

Sometimes it may be necessary to override the automatic selection of a
variant. For example, if you wish to have your variant chosen based on
data from an API call. This can be accomplished using the
`set_custom_assignment()` method.

```ruby
chosen_variant = 1
context.set_custom_assignment('experiment_name', chosen_variant)
```

If you are running multiple experiments and need to choose different
custom assignments for each one, you can do so using the
`set_custom_assignments()` method.

```ruby
assignments = [
    'experiment_name' => 1,
    'another_experiment_name' => 0,
    'a_third_experiment_name' => 2
]

context.set_custom_assignments(assignments)  
```

### Publish

Sometimes it is necessary to ensure all events have been published to the
A/B Smartly collector, before proceeding. You can explicitly call the
`publish()` methods.

```
context.publish
```

### Finalize

The `close()` method will ensure all events have been
published to the A/B Smartly collector, like `publish()`, and will also
"seal" the context, throwing an error if any method that could generate
an event is called.

```
context.close
```

### Tracking Goals

```ruby
context.track(
    'payment',
    { item_count: 1, total_amount: 1999.99 }
)
```

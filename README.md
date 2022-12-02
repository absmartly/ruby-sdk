# A/B Smartly SDK

A/B Smartly Ruby SDK

## Compatibility

The A/B Smartly Ruby SDK is compatible with Ruby versions 2.7 and later.  For the best performance and code readability, Ruby 3 or later is recommended. This SDK is being constantly tested with the nightly builds of Ruby, to ensure it is compatible with the latest Ruby version.

## Getting Started

### Install the SDK

Install the gem and add to the application's Gemfile by executing:

    $ bundle add absmartly

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install absmartly

## Basic Usage

Once the SDK is installed, it can be initialized in your project.

You can create an SDK instance using the API key, application name, environment, and the endpoint URL obtained from A/B Smartly.

```Ruby  
require 'absmartly'

Absmartly.configure_client do |config|
  config.endpoint = "https://your-company.absmartly.io/v1"
  config.api_key = "YOUR-API-KEY"
  config.application = "website"
  config.environment = "development"
end
```
#### Creating a new Context with raw promises

```Ruby  
# define a new context request
context_config = Absmartly.create_context_config
context_config.set_unit("session_id", "bf06d8cb5d8137290c4abb64155584fbdb64d8")
context_config.set_unit("user_id", "123456")

context = Absmartly.create_context(context_config)
```

### Selecting A Treatment

```Ruby
treatment = context.treatment('exp_test_experiment')

if treatment.zero?
  # user is in control group (variant 0)
else
  # user is in treatment group
end
```  

### Treatment Variables

```Ruby
default_button_color_value = 'red'
button_color = context.variable_value('button.color')
```

### Peek at Treatment Variants

Although generally not recommended, it is sometimes necessary to peek at a treatment or variable without triggering an exposure. The A/B Smartly SDK provides a `Context.peek_treatment()` method for that.

```Ruby
treatment = context.peek_treatment('exp_test_experiment')

if treatment.zero?
  # user is in control group (variant 0)
else
  # user is in treatment group
end
```  

#### Peeking at variables

```Ruby  
button_color = context.peek_variable_value('button.color', 'red')
```  

### Overriding Treatment Variants

During development, for example, it is useful to force a treatment for an  
experiment. This can be achieved with the `Context.set_override()` and/or `Context.set_overrides()`  methods. These methods can be called before the context is ready.

```Ruby
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
They can be set using the `context.set_attribute()` or `context.set_attributes()`  methods, before or after the context is ready.

```Ruby
context.set_attribute('session_id', session_id)
context.set_attributes(
    [
        'customer_age' => 'new_customer'
    ]
)
```  

### Custom Assignments

Sometimes it may be necessary to override the automatic selection of a variant. For example, if you wish to have your variant chosen based on data from an API call. This can be accomplished using the `Context.set_custom_assignment()` method.

```Ruby  
chosen_variant = 1
context.set_custom_assignment("experiment_name", chosen_variant)
```  

If you are running multiple experiments and need to choose different custom assignments for each one, you can do so using the `Context->setCustomAssignments()` method.

```Ruby  
assignments = [
    "experiment_name" => 1,
    "another_experiment_name" => 0,
    "a_third_experiment_name" => 2
]

context.set_custom_assignments(assignments)  
```

### Publish

Sometimes it is necessary to ensure all events have been published to the A/B Smartly collector, before proceeding. You can explicitly call the `context.publish()` method.

```Ruby
context.publish
```  

### Finalize

The `close()` method will ensure all events have been published to the A/B Smartly collector, like `context.publish()`, and will also "seal" the context, throwing an error if any method that could generate an event is called.

```Ruby
context.close
```

### Tracking Goals

```Ruby
context.track(
    'payment',
    { item_count: 1, total_amount: 1999.99 }
)
```



## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/omairazam/absmartly. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/omairazam/absmartly/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Absmartly project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/omairazam/absmartly/blob/master/CODE_OF_CONDUCT.md).

require_relative "../lib/absmartly"

# config file
Absmartly.configure_client do |config|
  config.endpoint = "https://demo.absmartly.io/v1"
  config.api_key = "x3ZyxmeKmb6n3VilTGs5I6-tBdaS9gYyr3i4YQXmUZcpPhH8nd8ev44NoEL_3yvA"
  config.application = "www"
  config.environment = "prod"
end

# main project
sdk = ABSmartly.create

context_config = ABSmartly.create_context_config
context_config.set_unit("session_id", "bf06d8cb5d8137290c4abb64155584fbdb64d8")
context_config.set_unit("user_id", "123456")

ctx = sdk.create_context(context_config)

treatment = ctx.getTreatment("exp_test_ab")
puts(treatment)

properties = {
  value: 125,
  fee: 125
}

ctx.track("payment", properties)

ctx.close
sdk.close

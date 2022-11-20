require_relative "../lib/absmartly"

# config file
Absmartly.configure_client do |config|
  config.endpoint = "https://demo.absmartly.io/v1"
  config.api_key = "x3ZyxmeKmb6n3VilTGs5I6-tBdaS9gYyr3i4YQXmUZcpPhH8nd8ev44NoEL_3yvA"
  config.application = "www"
  config.environment = "prod"
end

# main project
context_config = Absmartly.create_context_config
context_config.set_unit("session_id", "bf06d8cb5d8137290c4abb64155584fbdb64d8")
context_config.set_unit("user_id", "123456")

ctx = Absmartly.create_context(context_config)

treatment = ctx.treatment("exp_test_ab")
puts(treatment) # 0
treatment1 = ctx.treatment("net_seasons")
puts(treatment1) # 1
treatment2 = ctx.treatment("Experimento!")
puts(treatment2) # 1
treatment3 = ctx.treatment("test")
puts(treatment3) # 1

properties = {
  value: 125,
  fee: 125
}

ctx.track("payment", properties)

ctx.close
sdk.close

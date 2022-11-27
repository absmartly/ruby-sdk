require "byebug"
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

ctx.set_unit("db_user_id", 1000013)
ctx.set_units(db_user_id2: 1000013, session_id: 12311)

ctx.set_attribute("user_agent", "Chrome 2022")
ctx.set_attributes(
  customer_age: "new_customer",
  customer_point: 20,
)

ctx.set_override("new_exp", 3)
ctx.set_overrides(
  exp_test_experiment: 1,
  exp_another_experiment: 0,
)
ctx.publish
properties = {
  value: 125,
  fee: 125
}
ctx.track("payment", properties)

ctx.close

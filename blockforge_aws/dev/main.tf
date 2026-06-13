# Dev environment — wires the feature modules together.
# Review each module's variables.tf and pass the required inputs.

module "llm_proxy" {
  source = "../modules/llm_proxy"
  # TODO: set this module's input variables
}
module "static_site" {
  source = "../modules/static_site"
  # TODO: set this module's input variables
}
module "dns" {
  source = "../modules/dns"
  # TODO: set this module's input variables
}
module "infrastructure" {
  source = "../modules/infrastructure"
  # TODO: set this module's input variables
}

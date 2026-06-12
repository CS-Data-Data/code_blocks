# Module: llm-proxy
# A small relay that receives the app's AI requests and forwards them to Anthropic, adding the secret API key on the server so it never reaches anyone's browser.

# var.anthropic_api_key — The secret key for the AI service, kept out of the code and out of browsers.
variable "anthropic_api_key" {
  description = "Anthropic API key the proxy uses server-side"
  type        = string
  sensitive   = true
}

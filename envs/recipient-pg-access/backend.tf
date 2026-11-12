terraform {
  required_version = ">= 1.5.0"

  # Local state for a first deployment. For a shared or long-lived
  # environment, move it to an azurerm backend reached over a private endpoint.
  backend "local" {
    path = "terraform.tfstate"
  }
}

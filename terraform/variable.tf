variable "do_token" {
  description = "API token de DigitalOcean"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Ruta a la clave pública SSH"
  type        = string
  default     = "~/.ssh/do_infra_droplet.pub"
}

variable "region" {
  default = "nyc3"
}

variable "droplet_size" {
  description = "s-1vcpu-1gb = 1 vCPU / 1GB RAM, alcanza para Postgres + 3 apps chicas"
  default     = "s-1vcpu-1gb"
}
terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

variable "ssh_public_key" {
  type = string
}

variable "laptop_ip" {
  type = string
}

provider "hcloud" {
}

resource "hcloud_ssh_key" "main" {
  name       = "my-ssh-key"
  public_key = var.ssh_public_key
}

resource "hcloud_network" "privNet" {
  name     = "my-net"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "sub" {
  network_id   = hcloud_network.privNet.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.0.0/24"
}

resource "hcloud_firewall" "firewall" {
  name = "firewall"
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["${var.laptop_ip}/32"]
  }
}

resource "hcloud_server" "app" {
  name         = "app"
  image        = "ubuntu-24.04"
  server_type  = "ccx43"
  location     = "fsn1"
  ssh_keys     = [hcloud_ssh_key.main.id]
  depends_on   = [hcloud_network_subnet.sub]
  firewall_ids = [hcloud_firewall.firewall.id]

  network {
    ip         = "10.0.0.2"
    alias_ips  = ["10.0.0.3", "10.0.0.4", "10.0.0.5"] # more target IPs: one load generator runs out of local ports past ~64k connections per IP
    network_id = hcloud_network.privNet.id
  }
}

# shared vCPUs only because of the new-account dedicated vCPU limit; switch to ccx43 once it's raised
resource "hcloud_server" "db" {
  name         = "db"
  image        = "ubuntu-24.04"
  server_type  = "cpx62"
  location     = "fsn1"
  ssh_keys     = [hcloud_ssh_key.main.id]
  depends_on   = [hcloud_network_subnet.sub]
  firewall_ids = [hcloud_firewall.firewall.id]

  network {
    ip         = "10.0.0.10"
    network_id = hcloud_network.privNet.id

  }
}

resource "hcloud_server" "lg1" {
  name         = "lg1"
  image        = "ubuntu-24.04"
  server_type  = "cpx42"
  location     = "fsn1"
  ssh_keys     = [hcloud_ssh_key.main.id]
  depends_on   = [hcloud_network_subnet.sub]
  firewall_ids = [hcloud_firewall.firewall.id]

  network {
    ip         = "10.0.0.21"
    network_id = hcloud_network.privNet.id
  }
}

output "app_ip" {
  value = hcloud_server.app.ipv4_address
}

output "db_ip" {
  value = hcloud_server.db.ipv4_address
}

output "lg1_ip" {
  value = hcloud_server.lg1.ipv4_address
}

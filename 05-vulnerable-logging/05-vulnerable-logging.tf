terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  zone = "ru-central1-d"
}

data "yandex_client_config" "current" {}

resource "yandex_vpc_network" "unmonitored_vpc" {
  name = "unmonitored-vpc"
}

resource "yandex_mdb_mysql_cluster" "unlogged_mysql" {
  name           = "unlogged-mysql"
  environment    = "PRODUCTION"
  network_id     = yandex_vpc_network.unmonitored_vpc.id
  version        = "5.7"
  admin_password = "password123"

  resources {
    resource_preset_id = "db.small"
    disk_type_id       = "network-hdd"
    disk_size          = 20
  }

  host {
    zone      = "ru-central1-d"
    subnet_id = yandex_vpc_subnet.unmonitored_subnet.id
  }
}

resource "yandex_vpc_subnet" "unmonitored_subnet" {
  name           = "unmonitored-subnet"
  zone           = "ru-central1-d"
  network_id     = yandex_vpc_network.unmonitored_vpc.id
  v4_cidr_blocks = ["192.168.2.0/24"]
}

resource "yandex_storage_bucket" "unlogged_bucket" {
  bucket = "unlogged-bucket-${data.yandex_client_config.current.folder_id}"
}

resource "yandex_compute_instance" "unmonitored_instance" {
  name        = "unmonitored-instance"
  platform_id = "standard-v1"
  zone        = "ru-central1-d"

  resources {
    cores  = 1
    memory = 1
  }

  boot_disk {
    disk_size    = 20
    disk_type_id = "network-hdd"
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.unmonitored_subnet.id
    nat       = true
  }
}

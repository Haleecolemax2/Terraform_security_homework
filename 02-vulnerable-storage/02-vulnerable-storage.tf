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

resource "yandex_storage_bucket" "vulnerable_bucket" {
  bucket = "vulnerable-data-bucket-${data.yandex_client_config.current.folder_id}"
  acl    = "public-read"
}

resource "yandex_storage_bucket_encryption" "vulnerable" {
  bucket = yandex_storage_bucket.vulnerable_bucket.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "yandex_compute_disk" "unencrypted_volume" {
  name = "unencrypted-volume"
  size = 100
  type = "network-hdd"
  zone = "ru-central1-d"
}

resource "yandex_mdb_mysql_cluster" "vulnerable_mysql" {
  name           = "vulnerable-mysql"
  environment    = "PRODUCTION"
  network_id     = yandex_vpc_network.vulnerable_network.id
  version        = "5.7"
  admin_password = "insecurepassword123"

  resources {
    resource_preset_id = "db.small"
    disk_type_id       = "network-hdd"
    disk_size          = 20
  }

  host {
    zone      = "ru-central1-d"
    subnet_id = yandex_vpc_subnet.vulnerable_subnet.id
  }

  backup_window_start = "03:00"
  backup_retain_days  = 0
}

resource "yandex_storage_bucket_policy" "vulnerable_policy" {
  bucket = yandex_storage_bucket.vulnerable_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:*"
        Resource  = "*"
      }
    ]
  })
}

resource "yandex_vpc_network" "vulnerable_network" {
  name = "vulnerable-network"
}

resource "yandex_vpc_subnet" "vulnerable_subnet" {
  name           = "vulnerable-subnet"
  zone           = "ru-central1-d"
  network_id     = yandex_vpc_network.vulnerable_network.id
  v4_cidr_blocks = ["192.168.0.0/24"]
}

data "yandex_client_config" "current" {}

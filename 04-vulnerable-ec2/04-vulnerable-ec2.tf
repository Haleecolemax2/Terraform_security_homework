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

resource "yandex_vpc_network" "vulnerable_vpc" {
  name = "vulnerable-vpc"
}

resource "yandex_vpc_subnet" "public_subnet" {
  name           = "public-subnet"
  zone           = "ru-central1-d"
  network_id     = yandex_vpc_network.vulnerable_vpc.id
  v4_cidr_blocks = ["192.168.1.0/24"]
}

resource "yandex_vpc_security_group" "vulnerable_web" {
  name       = "vulnerable-web-sg"
  network_id = yandex_vpc_network.vulnerable_vpc.id

  ingress {
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_compute_disk" "boot_disk" {
  name     = "boot-disk-vulnerable"
  type     = "network-hdd"
  zone     = "ru-central1-d"
  size     = 20
  image_id = "fd84kd8dcu6tmnhbeebv"
}

resource "yandex_compute_instance" "vulnerable_ec2" {
  name        = "vulnerable-instance"
  platform_id = "standard-v1"
  zone        = "ru-central1-d"

  resources {
    cores  = 1
    memory = 1
  }

  boot_disk {
    disk_id = yandex_compute_disk.boot_disk.id
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.public_subnet.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.vulnerable_web.id]
  }

  metadata = {
    user-data = base64encode("#!/bin/bash\necho 'Admin password: MyAdminPassword123' > /var/log/app.log")
  }
}


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

variable "environment" {
  type    = string
  default = "production"
}

variable "project_name" {
  type    = string
  default = "secure-infrastructure"
}

variable "allowed_cidrs" {
  type    = list(string)
  default = ["192.168.0.0/16"]
}

resource "yandex_vpc_network" "secure" {
  name = "${var.project_name}-network"
}

resource "yandex_vpc_subnet" "private_app" {
  count          = 2
  name           = "${var.project_name}-private-app-subnet-${count.index + 1}"
  zone           = count.index == 0 ? "ru-central1-a" : "ru-central1-b"
  network_id     = yandex_vpc_network.secure.id
  v4_cidr_blocks = ["192.168.${10 + count.index}.0/24"]
}

resource "yandex_vpc_subnet" "private_db" {
  count          = 2
  name           = "${var.project_name}-private-db-subnet-${count.index + 1}"
  zone           = count.index == 0 ? "ru-central1-a" : "ru-central1-b"
  network_id     = yandex_vpc_network.secure.id
  v4_cidr_blocks = ["192.168.${20 + count.index}.0/24"]
}

resource "yandex_vpc_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  network_id  = yandex_vpc_network.secure.id
  description = "ALB"

  ingress {
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "HTTPS"
  }

  ingress {
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "HTTP"
  }

  egress {
    protocol          = "ANY"
    from_port         = 0
    to_port           = 65535
    predefined_target = "self_security_group"
    description       = "Internal"
  }
}

resource "yandex_vpc_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  network_id  = yandex_vpc_network.secure.id
  description = "App servers"

  ingress {
    protocol          = "TCP"
    port              = 8080
    security_group_id = yandex_vpc_security_group.alb.id
    description       = "ALB"
  }

  ingress {
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = var.allowed_cidrs
    description    = "SSH"
  }

  egress {
    protocol          = "TCP"
    port              = 3306
    security_group_id = yandex_vpc_security_group.database.id
    description       = "MySQL"
  }

  egress {
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "HTTPS"
  }
}

resource "yandex_vpc_security_group" "database" {
  name        = "${var.project_name}-database-sg"
  network_id  = yandex_vpc_network.secure.id
  description = "Database"

  ingress {
    protocol          = "TCP"
    port              = 3306
    security_group_id = yandex_vpc_security_group.app.id
    description       = "App"
  }

  egress {
    protocol       = "UDP"
    port           = 53
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "DNS"
  }
}

resource "yandex_storage_bucket" "app_data" {
  bucket = "${var.project_name}-app-data-${data.yandex_client_config.current.folder_id}"
  acl    = "private"
}

resource "yandex_storage_bucket_versioning" "app_data" {
  bucket = yandex_storage_bucket.app_data.id

  versioning_configuration {
    enabled = true
  }
}

resource "yandex_storage_bucket_server_side_encryption_configuration" "app_data" {
  bucket = yandex_storage_bucket.app_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "yandex_storage_bucket" "log_bucket" {
  bucket = "${var.project_name}-logs-${data.yandex_client_config.current.folder_id}"
  acl    = "private"
}

resource "yandex_storage_bucket_logging" "app_data" {
  bucket = yandex_storage_bucket.app_data.id

  target_bucket = yandex_storage_bucket.log_bucket.id
  target_prefix = "s3-access-logs/"
}

resource "yandex_mdb_mysql_cluster" "secure" {
  name           = "${var.project_name}-mysql"
  environment    = var.environment == "production" ? "PRODUCTION" : "PRESTABLE"
  network_id     = yandex_vpc_network.secure.id
  version        = "8.0"
  admin_password = random_password.db_admin_password.result

  resources {
    resource_preset_id = "db.small"
    disk_type_id       = "network-ssd"
    disk_size          = 20
  }

  database {
    name = "appdb"
  }

  user {
    name     = "appuser"
    password = random_password.db_user_password.result
  }

  host {
    zone      = "ru-central1-a"
    subnet_id = yandex_vpc_subnet.private_db[0].id
  }

  host {
    zone      = "ru-central1-b"
    subnet_id = yandex_vpc_subnet.private_db[1].id
  }

  backup_window_start = "03:00"
  backup_retain_days  = 30

  security_group_ids = [yandex_vpc_security_group.database.id]
}

resource "random_password" "db_admin_password" {
  length  = 32
  special = true
}

resource "random_password" "db_user_password" {
  length  = 32
  special = true
}

resource "yandex_lockbox_secret" "db_password" {
  name = "${var.project_name}-db-password"
}

resource "yandex_lockbox_secret_version" "db_password_v1" {
  secret_id = yandex_lockbox_secret.db_password.id
  entries {
    key        = "admin_user"
    text_value = "admin"
  }
  entries {
    key        = "admin_password"
    text_value = random_password.db_admin_password.result
  }
  entries {
    key        = "app_user"
    text_value = "appuser"
  }
  entries {
    key        = "app_password"
    text_value = random_password.db_user_password.result
  }
}

resource "yandex_iam_service_account" "secure_app" {
  name        = "${var.project_name}-app-sa"
  description = "App account"
}

resource "yandex_resourcemanager_folder_iam_member" "app_storage_admin" {
  folder_id = data.yandex_client_config.current.folder_id
  role      = "storage.admin"
  member    = "serviceAccount:${yandex_iam_service_account.secure_app.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "app_lockbox_reader" {
  folder_id = data.yandex_client_config.current.folder_id
  role      = "lockbox.payloadViewer"
  member    = "serviceAccount:${yandex_iam_service_account.secure_app.id}"
}

resource "yandex_iam_service_account_static_access_key" "app_key" {
  service_account_id = yandex_iam_service_account.secure_app.id
  description        = "App key"
}

resource "yandex_compute_disk" "app_disk_1" {
  name     = "${var.project_name}-app-disk-1"
  type     = "network-ssd"
  zone     = "ru-central1-a"
  size     = 20
  image_id = "fd84kd8dcu6tmnhbeebv"
}

resource "yandex_compute_disk" "app_disk_2" {
  name     = "${var.project_name}-app-disk-2"
  type     = "network-ssd"
  zone     = "ru-central1-b"
  size     = 20
  image_id = "fd84kd8dcu6tmnhbeebv"
}

resource "yandex_compute_instance" "app_1" {
  name        = "${var.project_name}-app-1"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    disk_id = yandex_compute_disk.app_disk_1.id
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private_app[0].id
    nat                = false
    security_group_ids = [yandex_vpc_security_group.app.id]
  }

  metadata = {
    user-data = base64encode("#!/bin/bash\necho 'Instance 1 ready'")
  }

  service_account_id = yandex_iam_service_account.secure_app.id
}

resource "yandex_compute_instance" "app_2" {
  name        = "${var.project_name}-app-2"
  platform_id = "standard-v3"
  zone        = "ru-central1-b"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    disk_id = yandex_compute_disk.app_disk_2.id
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.private_app[1].id
    nat                = false
    security_group_ids = [yandex_vpc_security_group.app.id]
  }

  metadata = {
    user-data = base64encode("#!/bin/bash\necho 'Instance 2 ready'")
  }

  service_account_id = yandex_iam_service_account.secure_app.id
}

resource "yandex_lb_network_load_balancer" "alb" {
  name        = "${var.project_name}-nlb"
  description = "NLB"

  listener {
    name        = "http"
    port        = 80
    target_port = 8080

    external_address_spec {
      ip_version = "ipv4"
    }
  }

  listener {
    name        = "https"
    port        = 443
    target_port = 8080

    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_lb_target_group.app_targets.id

    healthcheck {
      name = "tcp"
      tcp_options {
        port = 8080
      }
    }
  }
}

resource "yandex_lb_target_group" "app_targets" {
  name        = "${var.project_name}-targets"
  description = "App targets"

  targets {
    subnet_id = yandex_vpc_subnet.private_app[0].id
    address   = yandex_compute_instance.app_1.network_interface.0.ip_address
  }

  targets {
    subnet_id = yandex_vpc_subnet.private_app[1].id
    address   = yandex_compute_instance.app_2.network_interface.0.ip_address
  }
}

resource "yandex_audit_trail" "secure" {
  name               = "${var.project_name}-audit-trail"
  folder_id          = data.yandex_client_config.current.folder_id
  service_account_id = yandex_iam_service_account.audit.id

  storage_destination {
    bucket_name = yandex_storage_bucket.audit_logs.id
  }
}

resource "yandex_iam_service_account" "audit" {
  name = "${var.project_name}-audit-sa"
}

resource "yandex_resourcemanager_folder_iam_member" "audit_storage" {
  folder_id = data.yandex_client_config.current.folder_id
  role      = "audit-trails.viewer"
  member    = "serviceAccount:${yandex_iam_service_account.audit.id}"
}

resource "yandex_storage_bucket" "audit_logs" {
  bucket = "${var.project_name}-audit-logs-${data.yandex_client_config.current.folder_id}"
  acl    = "private"
}

resource "yandex_storage_bucket_versioning" "audit_logs" {
  bucket = yandex_storage_bucket.audit_logs.id

  versioning_configuration {
    enabled = true
  }
}

output "nlb_public_ip" {
  value = yandex_lb_network_load_balancer.alb.listener.0.external_address_spec.0.address
}

output "app_instance_1_ip" {
  value = yandex_compute_instance.app_1.network_interface.0.ip_address
}

output "app_instance_2_ip" {
  value = yandex_compute_instance.app_2.network_interface.0.ip_address
}

output "mysql_host" {
  value     = yandex_mdb_mysql_cluster.secure.host.0.fqdn
  sensitive = true
}

output "service_account_id" {
  value = yandex_iam_service_account.secure_app.id
}

output "storage_bucket" {
  value = yandex_storage_bucket.app_data.id
}

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

resource "yandex_iam_service_account" "vulnerable_admin" {
  name = "vulnerable-admin-sa"
}

resource "yandex_resourcemanager_folder_iam_member" "admin_full_access" {
  folder_id = data.yandex_client_config.current.folder_id
  role      = "admin"
  member    = "serviceAccount:${yandex_iam_service_account.vulnerable_admin.id}"
}

resource "yandex_iam_service_account_static_access_key" "vulnerable_key" {
  service_account_id = yandex_iam_service_account.vulnerable_admin.id
}

resource "yandex_iam_service_account" "overly_trusted" {
  name = "overly-trusted-sa"
}

resource "yandex_resourcemanager_folder_iam_member" "overly_trusted_member" {
  folder_id = data.yandex_client_config.current.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.overly_trusted.id}"
}

resource "yandex_iam_service_account_iam_member" "unrestricted_assume" {
  service_account_id = yandex_iam_service_account.overly_trusted.id
  role               = "iam.serviceAccountUser"
  member             = "serviceAccount:${yandex_iam_service_account.vulnerable_admin.id}"
}

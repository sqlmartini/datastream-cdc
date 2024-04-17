/******************************************
Local variables declaration
 *****************************************/

locals {
project_id                  = "${var.project_id}"
project_nbr                 = "${var.project_number}"
admin_upn_fqn               = "${var.gcp_account_name}"
location                    = "${var.gcp_region}"
umsa                        = "cdc-lab-sa"
umsa_fqn                    = "${local.umsa}@${local.project_id}.iam.gserviceaccount.com"
vpc_nm                      = "vpc-main"
spark_subnet_nm             = "spark-snet"
spark_subnet_cidr           = "10.0.0.0/16"
composer_subnet_nm          = "composer-snet"
composer_subnet_cidr        = "10.1.0.0/16"
compute_subnet_nm           = "compute-snet"
compute_subnet_cidr         = "10.2.0.0/16"
GCE_GMSA_FQN                = "${local.project_nbr}-compute@developer.gserviceaccount.com"
cloudsql_bucket_nm          = "${local.project_id}-cloudsql-backup"
}

/******************************************
1. User Managed Service Account Creation
 *****************************************/
module "umsa_creation" {
  source     = "terraform-google-modules/service-accounts/google"
  version = "4.2.2"
  project_id = local.project_id
  names      = ["${local.umsa}"]
  display_name = "User Managed Service Account"
  description  = "User Managed Service Account for CDC"
}

/******************************************
2a. IAM role grants to User Managed Service Account
 *****************************************/

module "umsa_role_grants" {
  source                  = "terraform-google-modules/iam/google//modules/member_iam"
  version = "7.7.1"
  service_account_address = "${local.umsa_fqn}"
  prefix                  = "serviceAccount"
  project_id              = local.project_id
  project_roles = [    
    "roles/iam.serviceAccountUser",
    "roles/iam.serviceAccountTokenCreator",
    "roles/storage.objectViewer",
    "roles/storage.admin",
    "roles/bigquery.dataEditor",
    "roles/bigquery.admin",
    "roles/iam.serviceAccountUser",
    "roles/cloudsql.client",
  ]
  depends_on = [module.umsa_creation]
}

/******************************************************
3. Service Account Impersonation Grants to Admin User
 ******************************************************/

module "umsa_impersonate_privs_to_admin" {
  source  = "terraform-google-modules/iam/google//modules/service_accounts_iam/"
  version = "7.7.1"
  service_accounts = ["${local.umsa_fqn}"]
  project          = local.project_id
  mode             = "additive"
  bindings = {
    "roles/iam.serviceAccountUser" = [
      "user:${local.admin_upn_fqn}"
    ],
    "roles/iam.serviceAccountTokenCreator" = [
      "user:${local.admin_upn_fqn}"
    ]
  }
  depends_on = [
    module.umsa_creation
  ]
}

/******************************************************
4. IAM role grants to Admin User
 ******************************************************/

module "administrator_role_grants" {
  source   = "terraform-google-modules/iam/google//modules/projects_iam"
  version = "7.7.1"
  projects = ["${local.project_id}"]
  mode     = "additive"

  bindings = {
    "roles/storage.admin" = [
      "user:${local.admin_upn_fqn}",
    ]
    "roles/bigquery.admin" = [
      "user:${local.admin_upn_fqn}",
    ]
    "roles/bigquery.user" = [
      "user:${local.admin_upn_fqn}",
    ]
    "roles/bigquery.dataEditor" = [
      "user:${local.admin_upn_fqn}",
    ]
    "roles/bigquery.jobUser" = [
      "user:${local.admin_upn_fqn}",
    ]
    "roles/composer.environmentAndStorageObjectViewer" = [
      "user:${local.admin_upn_fqn}",
    ]
    "roles/iam.serviceAccountUser" = [
      "user:${local.admin_upn_fqn}",
    ]
    "roles/iam.serviceAccountTokenCreator" = [
      "user:${local.admin_upn_fqn}",
    ]
  }
  depends_on = [
    module.umsa_role_grants,
    module.umsa_impersonate_privs_to_admin
  ]

  }

/*******************************************
Introducing sleep to minimize errors from
dependencies having not completed
********************************************/
resource "time_sleep" "sleep_after_identities_permissions" {
  create_duration = "120s"
  depends_on = [
    module.umsa_creation,
    module.umsa_role_grants,
    module.umsa_impersonate_privs_to_admin,
    module.administrator_role_grants
  ]
}

/******************************************
5. VPC Network & Subnet Creation
 *****************************************/
module "vpc_creation" {
  source                                 = "terraform-google-modules/network/google"
  version                                = "9.0.0"
  project_id                             = local.project_id
  network_name                           = local.vpc_nm
  routing_mode                           = "REGIONAL"

  subnets = [
    {
      subnet_name           = "${local.spark_subnet_nm}"
      subnet_ip             = "${local.spark_subnet_cidr}"
      subnet_region         = "${local.location}"
      subnet_range          = local.spark_subnet_cidr
      subnet_private_access = true
    }
    ,
    {
      subnet_name           = "${local.composer_subnet_nm}"
      subnet_ip             = "${local.composer_subnet_cidr}"
      subnet_region         = "${local.location}"
      subnet_range          = local.composer_subnet_cidr
      subnet_private_access = true
    }    
    ,
    {
      subnet_name           = "${local.compute_subnet_nm}"
      subnet_ip             = "${local.compute_subnet_cidr}"
      subnet_region         = "${local.location}"
      subnet_range          = local.compute_subnet_cidr
      subnet_private_access = true
    }    
  ]
  depends_on = [time_sleep.sleep_after_identities_permissions]
}

/******************************************
6. Firewall rules creation
 *****************************************/

resource "google_compute_firewall" "allow_intra_snet_ingress_to_any" {
  project   = local.project_id 
  name      = "allow-intra-snet-ingress-to-any"
  network   = local.vpc_nm
  direction = "INGRESS"
  source_ranges = [local.spark_subnet_cidr]
  allow {
    protocol = "all"
  }
  description        = "Creates firewall rule to allow ingress from within Spark subnet on all ports, all protocols"
  depends_on = [module.vpc_creation]
}

/*******************************************
Introducing sleep to minimize errors from
dependencies having not completed
********************************************/
resource "time_sleep" "sleep_after_network_and_firewall_creation" {
  create_duration = "120s"
  depends_on = [
    module.vpc_creation
  ]
}

/******************************************
10. Cloud SQL instance creation
******************************************/

module "sql-db_private_service_access" {
  source        = "terraform-google-modules/sql-db/google//modules/private_service_access"
  version = "19.0.0"
  project_id    = local.project_id
  vpc_network   = local.vpc_nm
  depends_on = [ 
        time_sleep.sleep_after_network_and_firewall_creation
   ]  
}

module "sql-db_mssql" {
  source            = "terraform-google-modules/sql-db/google//modules/mssql"
  name              = local.project_id
  project_id        = local.project_id
  region            = local.location  
  availability_type = "ZONAL"
  database_version  = "SQLSERVER_2022_STANDARD"
  disk_size         = 100
  root_password     = "P@ssword@111"
  ip_configuration  = {
    "allocated_ip_range": null,
    "authorized_networks": [],
    "ipv4_enabled": true,
    "private_network": module.vpc_creation.network_id,
    "require_ssl": true
    }
  depends_on = [module.sql-db_private_service_access]
}

#Storage bucket for SQL Server backup file
resource "google_storage_bucket" "cloudsql_bucket_creation" {
  project                           = local.project_id 
  name                              = local.cloudsql_bucket_nm
  location                          = local.location
  uniform_bucket_level_access       = true
  force_destroy                     = true
  depends_on = [module.sql-db_private_service_access]
}

#Grant Cloud SQL service account access to import backup from cloud storage
resource "google_storage_bucket_iam_member" "member" {
  bucket = google_storage_bucket.cloudsql_bucket_creation.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${module.sql-db_mssql.instance_service_account_email_address}"
  depends_on = [module.sql-db_mssql]
}

/******************************************
11. Create Cloud SQL Proxy
******************************************/

#Create static internal IP for VM
module "sql_proxy_address" {
  source     = "terraform-google-modules/address/google"
  version    = "~> 3.1"
  project_id = local.project_id
  region     = local.location
  subnetwork = local.compute_subnet_nm
  names      = ["sql-proxy-ip"]
  depends_on = [
    module.vpc_creation
  ]
}

#Create SQL proxy VM
resource "google_compute_instance" "sql-proxy" {
  name         = "sql-proxy"
  project      = local.project_id 
  machine_type = "g1-small"
  zone         = "us-central1-a"
  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable-109-17800-66-27"
    }
  }
  network_interface {
    subnetwork = local.compute_subnet_nm    
    subnetwork_project = local.project_id
    network_ip = tolist(module.sql_proxy_address.addresses)[0] 
    access_config {}
  }
  service_account {
    email  = local.umsa_fqn
    scopes = ["cloud-platform"]
  }
  scheduling {
    on_host_maintenance = "MIGRATE"
  }
  metadata = {
    startup-script = "docker run -d -p 0.0.0.0:1433:1433 gcr.io/cloudsql-docker/gce-proxy:latest /cloud_sql_proxy -instances=${local.project_id}:${local.location}:${local.project_id}=tcp:0.0.0.0:1433"
  }
  depends_on = [module.sql_proxy_address]
}

#Output static IP for JDBC connection
output "sql_proxy_ip" {
  value = tolist(module.sql_proxy_address.addresses)[0]
}

/******************************************
DONE
******************************************/
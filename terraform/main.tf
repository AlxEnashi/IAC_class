module "network" {
  source  = "./modules/network"
  project = var.project
}

module "compute" {
  source              = "./modules/compute"
  project             = var.project
  vpc_id              = module.network.vpc_id
  subnet_id           = module.network.subnet_id
  instance_type       = var.instance_type
  my_ip_cidr          = var.my_ip_cidr
  ssh_public_key_path = var.ssh_public_key_path
}

module "cdn" {
  source      = "./modules/cdn"
  project     = var.project
  origin_host = module.compute.public_dns
}

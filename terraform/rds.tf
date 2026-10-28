# orders-db, moved off docker-compose onto RDS. Private: publicly_accessible
# = false means AWS publishes the instance's *private* IP in public DNS, so
# HCP Vault Dedicated resolves the plain endpoint hostname to 10.90.x.x and
# reaches it over the HVN peering (terraform/hcp.tf) -- no hardcoded IP, no
# TLS-hostname mismatch, no public exposure of a password-authenticated
# database.
resource "aws_db_subnet_group" "orders_db" {
  name       = "${var.cluster_name}-orders-db"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "orders_db" {
  name   = "${var.cluster_name}-orders-db"
  vpc_id = module.vpc.vpc_id

  # Only the HVN's CIDR and the presenter's own IP can reach Postgres --
  # not the whole VPC, not the internet. The presenter doesn't connect
  # directly either; see k8s_manifests/orders-db-proxy.yaml + the
  # port-forward in scripts/bootstrap-eks.sh for how local psql reaches it.
  ingress {
    description = "Postgres from the HCP HVN (Vault database secrets engine)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.hcp_hvn.main.cidr_block]
  }

  ingress {
    description = "Postgres from inside the VPC (the orders-db-proxy pod)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "orders_db" {
  identifier     = "${var.cluster_name}-orders-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t3.micro"

  allocated_storage   = 20
  storage_encrypted   = true
  publicly_accessible = false

  db_name  = "orders"
  username = "orders_admin"
  password = var.orders_db_admin_password

  db_subnet_group_name   = aws_db_subnet_group.orders_db.name
  vpc_security_group_ids = [aws_security_group.orders_db.id]

  skip_final_snapshot = true
  deletion_protection  = false

  # Short-lived demo cluster -- no Multi-AZ, no extended backups.
  backup_retention_period = 0
  multi_az                = false
}

provider "aws" {
  region = "us-east-1"
}

module "network" {
  source                 = "./modules/network"
  vpc_name               = "vpc-1"
  vpc_cidr               = var.vpc
  subnet_1a_public_cidr  = var.pub_sub_1a
  subnet_1b_public_cidr  = var.pub_sub_1b
  subnet_1a_private_cidr = var.priv_sub_1a
  subnet_1b_private_cidr = var.priv_sub_1b
}

module "ecs" {
  source               = "./modules/ecs"
  ecs_subnets          = module.network.private_subnets
  ecs_container_name   = "demo"
  ecs_port             = var.ecs_port # we use networkMode awsvpc so host and container ports should match
  ecs_task_def_name    = "demo-task"
  ecs_docker_image     = "afonsoaugusto/api-uuid"
  vpc_id               = module.network.vpc_id
  alb_sg               = module.alb.alb_sg
  alb_target_group_arn = module.alb.alb_tg_arn
}

module "alb" {
  source         = "./modules/alb"
  alb_subnets    = module.network.private_subnets
  vpc_id         = module.network.vpc_id
  ecs_sg         = module.ecs.ecs_sg
  alb_port       = var.alb_port
  ecs_port       = var.ecs_port
  default_vpc_sg = module.network.default_vpc_sg
  vpc_cidr       = var.vpc # Allow inbound client traffic via AWS PrivateLink on the load balancer listener port
}

module "nlb" {
  source            = "./modules/nlb"
  nlb_subnets       = module.network.private_subnets
  vpc_id            = module.network.vpc_id
  alb_arn           = module.alb.alb_arn
  nlb_port          = var.nlb_port
  alb_listener_port = module.alb.alb_listener_port
}

resource "aws_vpc_endpoint_service" "privatelink" {
  acceptance_required        = false
  network_load_balancer_arns = [module.nlb.nlb_arn]
  #checkov:skip=CKV_AWS_123:For this demo I don't need to configure the VPC Endpoint Service for Manual Acceptance
}

### Deploy of Second (added) VPC which will use VPCE and Privatelink to connect
module "network_added" {
  source                 = "./modules/network"
  vpc_name               = "vpc-2"
  vpc_cidr               = var.vpc_added
  subnet_1a_public_cidr  = var.pub_sub_1a_added
  subnet_1b_public_cidr  = var.pub_sub_1b_added
  subnet_1a_private_cidr = var.priv_sub_1a_added
  subnet_1b_private_cidr = var.priv_sub_1b_added
}

resource "aws_vpc_endpoint" "vpce" {
  vpc_id             = module.network_added.vpc_id
  service_name       = aws_vpc_endpoint_service.privatelink.service_name
  vpc_endpoint_type  = "Interface"
  security_group_ids = [aws_security_group.vpce_sg.id]
  subnet_ids         = module.network_added.public_subnets
}

resource "aws_security_group" "vpce_sg" {
  vpc_id = module.network_added.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    cidr_blocks = [var.vpc_added]
    protocol    = "tcp"
    description = "Allow communication to PrivateLink endpoint"
  }
}

module "ec2_instance_added" {
  source                      = "terraform-aws-modules/ec2-instance/aws"
  version                     = "~> 3.0"
  name                        = "test-instance-vpc-2"
  associate_public_ip_address = true
  ami                         = "ami-0ec2468df0eaa55ff" # us-east-1 specific
  instance_type               = "t2.micro"
  key_name                    = var.key
  vpc_security_group_ids      = [aws_security_group.ssh_sg_added.id]
  subnet_id                   = element(module.network_added.public_subnets, 0)
}

resource "aws_security_group" "ssh_sg_added" {
  vpc_id      = module.network_added.vpc_id
  description = "Allow SSH from anywhere"

  ingress {
    from_port = 22
    to_port   = 22
    #checkov:skip=CKV_AWS_24:For this demo I do allow SSH from anywhere
    cidr_blocks = ["0.0.0.0/0"]
    protocol    = "tcp"
    description = "Allow SSH"
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

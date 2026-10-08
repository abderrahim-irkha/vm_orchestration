# This module creates an Auto Scaling Group (ASG) with a launch template, security group, and optional instance refresh configuration. It also creates a service-linked role for Auto Scaling if requested.


## This data source retrieves the most recent Amazon Linux AMI created by the Packer build. It filters the AMIs by name and owner to ensure that only the correct AMI is selected.
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["self"] # Use the AMI created by the Packer build

  filter {
    name   = "name"
    values = [var.ami_name]
  }
}

## This data source retrieves the default VPC in the AWS account. The default VPC is used to launch the EC2 instances in the ASG.

data "aws_vpc" "default" {
  default = true
}

## This data source retrieves the default subnet in the default VPC. The default subnet is used to launch the EC2 instances in the ASG.

data "aws_subnet" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

## The following resources create the launch template, security group, and auto scaling group for the application.

resource "aws_launch_template" "sample_app" {
  name_prefix   = var.name
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  user_data     = var.user_data
  vpc_security_group_ids = [aws_security_group.sample_app.id]
  key_name     = var.key_name
}

resource "aws_security_group" "sample_app" {
  name = var.name
  description = "Allow HTTP traffic to ${var.name}"
}

resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  from_port         = var.app_http_port
  to_port           = var.app_http_port
  protocol          = "tcp"
  security_group_id = aws_security_group.sample_app.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "allow_ssh_inbound" {
  count             = var.key_name == null ? 0 : 1   # Only create this rule if a key name is provided
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = aws_security_group.sample_app.id
  cidr_blocks       = ["0.0.0.0/0"]
}

## The following resource creates the auto scaling group (ASG) for the application. It uses the launch template and security group created above, and it can optionally register instances with target groups and enable instance refresh.

resource "aws_autoscaling_group" "sample_app" {
  name_prefix               = var.name
  max_size                  = var.max_size
  min_size                  = var.min_size
  desired_capacity          = var.desired_capacity
  vpc_zone_identifier       = [data.aws_subnet.default.id]
  
  launch_template {
    id      = aws_launch_template.sample_app.id
    version = aws_launch_template.sample_app.latest_version
  }
  
  tag {
    key                 = "Name"
    value               = var.name
    propagate_at_launch = true
  }

  target_group_arns = var.target_group_arns
  health_check_type = len(var.target_group_arns) > 0 ? "ELB" : "EC2"

  dynamic "instance_refresh" {
    for_each = var.instance_refresh == null ? [] : [1]
    content {
      strategy = "Rolling"

      preferences {
        min_healthy_percentage = instance_refresh.value.min_healthy_percentage
        max_healthy_percentage = instance_refresh.value.max_healthy_percentage
        auto_rollback          = instance_refresh.value.auto_rollback
      }
    }
  }
}

## The following resource creates a service-linked role for Auto Scaling if the `create_service_linked_role` variable is set to true. This role is required for Auto Scaling to function properly in AWS accounts that have never used Auto Scaling before.

resource "aws_iam_service_linked_role" "auto_scaling" {
  count            = var.create_service_linked_role ? 1 : 0
  aws_service_name = "autoscaling.amazonaws.com"
}
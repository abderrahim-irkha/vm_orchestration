# The following resources create the application load balancer, target group, listener, and security group for the application.

## This data source retrieves the default VPC in the AWS account. The default VPC is used to launch the EC2 instances in the ASG.

data "aws_vpc" "default" {
  default = true
}

## This data source retrieves the default subnet in the default VPC. The default subnet is used to launch the EC2 instances in the ASG.

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

## This resource creates the application load balancer (ALB) for the application. It uses the security group created below and the default subnets in the default VPC.

resource "aws_lb" "sample_app" {
  name               = var.name
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

## The following resources create the target group and listener for the application load balancer (ALB). The target group is used to register the EC2 instances in the auto scaling group (ASG) with the ALB, and the listener is used to forward HTTP requests from the ALB to the target group.

resource "aws_lb_target_group" "sample_app" {
  name     = var.name
  port     = var.app_http_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    matcher             = "200"
    path                = var.app_health_check_path
  }
}

## The following resource creates the listener for the application load balancer (ALB). The listener is used to forward HTTP requests from the ALB to the target group.

resource "aws_lb_listener" "sample_app" {
  load_balancer_arn = aws_lb.sample_app.arn
  port              = var.alb_http_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sample_app.arn
  }
}

## The following resources create the security group for the application load balancer (ALB). The security group allows inbound HTTP traffic on the ALB port and allows all outbound traffic.

resource "aws_security_group" "alb" {
  name        = var.name
  description = "Allow HTTP traffic into ${var.name}"
}

## The following resources create the security group rules for the application load balancer (ALB). The first rule allows inbound HTTP traffic on the ALB port, and the second rule allows all outbound traffic.

resource "aws_security_group_rule" "alb_allow_http_inbound" {
  type              = "ingress"
  protocol          = "tcp"
  from_port         = var.alb_http_port
  to_port           = var.alb_http_port
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "alb_allow_all_outbound" {
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = ["0.0.0.0/0"]
}
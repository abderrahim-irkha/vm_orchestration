packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

data "amazon-ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"] # Use the official Amazon AMI owner ID
  region      = "us-east-2"

  filters = {
    name = "al2023-ami-2023.*-x86_64"
  }
}

source "amazon-ebs" "amazon_linux" {
  ami_name      = "sample-app-${uuidv4()}"
  instance_type = "t3.micro"
  region        = "us-east-2"
  source_ami    = data.amazon-ami.amazon_linux.id
  ssh_username  = "ec2-user"
}

build {
  sources = ["source.amazon-ebs.amazon_linux"]

  provisioner "file" {
    sources     = ["sample-app"]
    destination = "/tmp"
  }

  provisioner "shell" {
    script       = "install-node.sh"
    pause_before = "30s"
  }
}
# Deploy a sample Node.js application using VM orchestration on AWS with Packer and Terraform as IaC tools 

This repository provides a production-ready Infrastructure as Code (IaC) framework for deploying a sample Node.js application on AWS using an automated VM Orchestration approach. Build a VM image using Packer, deploy the VM image across multiple instances using Terraform, configure a load balancer to distribute load across the instances, and roll out updates across the instances with zero downtime.

## Authenticate to AWS

Prerequisites:
An Access Key ID and a Secret Access Key are generated from the AWS IAM Console under Users -> [Your Username] -> Security credentials -> Create access key

1 - Open your terminal and run:
```bash
$aws configure
```

2 - Provide the following inputs when prompted:
- AWS Access Key ID: Paste your access key.
- AWS Secret Access Key: Paste your secret key.
- Default region name: Enter your target region (e.g., us-east-2, as this project will provision all the infrastructure in this region).
- Default output format: Type json (or leave blank)

For more information, check the AWS documentation: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-quickstart.html

## Building the VM image using Packer

The Packer template file packer/sample-app.pkr.hcl contains the configuration for building a VM image

```hcl
packer {                                             #1
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

data "amazon-ami" "amazon_linux" {                   #2
  most_recent = true
  owners      = ["amazon"] # Use the official Amazon AMI owner ID
  region      = "us-east-2"

  filters = {
    name = "al2023-ami-2023.*-x86_64"
  }
}

source "amazon-ebs" "amazon_linux" {                 #3
  ami_name      = "sample-app-${uuidv4()}"
  instance_type = "t3.micro"
  region        = "us-east-2"
  source_ami    = data.amazon-ami.amazon_linux.id
  ssh_username  = "ec2-user"
}

build {                                              #4
  sources = ["source.amazon-ebs.amazon_linux"]

  provisioner "file" {                               #5
    sources     = ["sample-app"]
    destination = "/tmp"
  }

  provisioner "shell" {                              #6
    script       = "install-node.sh"
    pause_before = "30s"
  }
}
```

#### The preceding code does the following:

1. Specifies the required provider 
2. Looks up the ID of the Amazon Linux AMI: Use the "amazon-ami"
3. Source images: Packer will start a server running each source image you specify. This code will result in Packer starting an EC2 instance running the Amazon Linux AMI from #2
4. Build steps: Packer then connects to the server (e.g., via SSH) and runs the build steps in the order you specified. When all the build steps have finished, Packer will take a snapshot of the server and shut down the server. This snapshot will be a new AMI that you can deploy, and its name will be set based on the name parameter in the source block from #3, which the preceding code sets to sample-app-packer-UUID, where UUID is a randomly generated value that ensures you get a unique AMI name every time you run packer build. This code runs two build steps, as described in #5 and #6.
5. File Provisioner: Copy the sample-app folder onto the server. Note that you initially copy it into the /tmp folder; the install-node.sh script next will move it to its final destination.
6. Shell provisioner: The second build step runs a shell provisioner to execute shell scripts on the server. The code uses this to run the install-node.sh script, which is described next.

### Bash script to install Node.js and configure the server for running the sample app:

```bash
#!/usr/bin/env bash

set -e

sudo tee /etc/yum.repos.d/nodesource-nodejs.repo > /dev/null <<EOF
[nodesource-nodejs]
baseurl=https://rpm.nodesource.com/pub_23.x/nodistro/nodejs/x86_64
gpgkey=https://rpm.nodesource.com/gpgkey/ns-operations-public.key
EOF                                                                   #1
sudo yum install -y nodejs                                            #2

sudo adduser app-user                                                 #3
sudo mv /tmp/sample-app /home/app-user                                #4
sudo chown -R app-user /home/app-user/sample-app                      #5
sudo npm install pm2@latest -g                                        #6
eval "$(sudo -u app-user pm2 startup -u app-user | tail -n1)"         #7
```

#### The preceding code does the following:

1. Add the Node.js repo
2. Install Node.js
3. Create app-user. This will also automatically create a home folder for app-user
4. Move the sample-app folder from the /tmp folder to app-user’s home folder.
5. Make the app-user the owner of the sample-app folder.
6. Install PM2. (PM2 is a process supervisor alternative to Systemd)
7. Configure PM2 to run on boot (as app-user).

### To build the VM image, run the following commands:

```bash
$cd packer/
$packer init sample-app.pkr.hcl
$packer build sample-app.pkr.hcl
```

When the build is done, Packer will output the ID of the newly created AMI, which you will deploy next.

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


## Deploy a cluster in AWS Auto Scaling Group (ASG) to run the sample app

We will use a module called "asg"; you can find this module in the terraform/modules/asg folder. This is a simple module that creates three main resources:

* A launch template, which is a bit like a blueprint that specifies the configuration to use for each EC2 instance.
* An ASG that uses the configuration in the launch template to stamp out EC2 instances. The ASG will deploy these instances into the default VPC
* A security group that controls what traffic can go in and out of the instances.

### Configure the ASG module (terraform/live/asg-sample/main.tf)

```hcl
provider "aws" {
  region = "us-east-2"
}

module "asg" {
  source  = "../../modules/asg"

  name          = "sample-app-asg"                             #1
  ami_name      = "sample-app-*"                               #2
  user_data     = filebase64("${path.module}/user-data.sh")    #3
  app_http_port = 8080                                         #4

  instance_type = "t3.micro"                                   #5
  min_size      = 3                                            #6
  max_size      = 10                                           #7

  instance_refresh = {
    min_healthy_percentage = 100
    max_healthy_percentage = 200
    auto_rollback          = true
  }
}
```

#### This code sets the following parameters on the "asg" module:

1. name: The name to use for the launch template, ASG, etc.
2. ami_name: The name of the AMI to run on each EC2 instance. The preceding code sets this to the name of the AMI you built from the Packer template in the previous section.
3. user_data: The user data script to run on each instance during boot. (We will see that in a bit)
4. app_http_port: The port to open in the security group to allow the app to receive HTTP requests.
5. instance_type: The type of instances to run in the ASG.
6. min_size: The minimum number of instances to run in the ASG.
7. max_size: The maximum number of instances to run in the ASG.

### The user data script (terraform/live/asg-sample/user-data.sh)

```bash
#!/usr/bin/env bash

set -e

su app-user <<'EOF'
cd /home/app-user/sample-app
pm2 start app.config.js
pm2 save
EOF
```

This user data script switches to app-user, goes into the sample-app folder where Packer copied the sample app code, uses PM2 to run the sample app, and then saves the sample app to the list of apps that should be restarted after a reboot.

## Deploy the application load balancer (ELB)

We will use a module called alb in the terraform/modules/alb folder to deploy an ALB. It’s a simple module that deploys the ALB into the default VPC and configures it to forward all requests to your servers

### Configure the ALB module (terraform/live/asg-sample/main.tf)

```hcl
provider "aws" {
  region = "us-east-2"
}

module "asg" {
  source  = "../../modules/asg"

  # ... (other params omitted) ...
}

module "alb" {
  source  = "../../modules/alb"

  name                  = "sample-app-alb"    #1
  alb_http_port         = 80                  #2
  app_http_port         = 8080                #3
  app_health_check_path = "/"                 #4
}
```

#### This code sets the following parameters on the "alb" module:

1. name: The name to use for the ALB and all other resources.
2. alb_http_port: The port the ALB will listen on for HTTP requests.
3. app_http_port: The port the app will listen on for HTTP requests. The ALB will send traffic to this port. It will also perform health checks on this port, sending each server a request every 30 seconds, and considering the server healthy (and therefore routing traffic to it) only if it returns a 200 OK.
4. app_health_check_path: The path to use in the app for health checks.

One piece is missing: how does the ALB know which EC2 instances to send traffic to? To connect the ALB and ASG, make the changes below

```hcl
provider "aws" {
  region = "us-east-2"
}

module "asg" {
  source  = "../../modules/asg"
  
  # ... (other params omitted) ...

  target_group_arns = [module.alb.target_group_arn]

}
```

Setting target_group_arns will change the ASG behavior in the following ways:

* Auto registration:

    The ASG will now register its instances with the ALB, including the initial instances from when you launch the ASG, as well as any instances that launch later (e.g., as a result of a deployment, auto healing, or auto scaling).

* Auto healing:

    By default, the auto-healing feature in the ASG replaces an instance only if it has crashed (a hardware issue), but if the app has crashed (a software issue) and the instance is still running, the ASG won’t know to replace it. Setting the target_group_arns parameter configures the ASG to use the ALB for health checks, so auto healing will handle both hardware and software issues.

#### The load balancer’s domain name will be produced as an output variable in outputs.tf

```hcl
output "alb_dns_name" {
  description = "The ALB's domain name"
  value       = module.alb.alb_dns_name
}
```

### To deploy the module, run the following commands:

```bash
$terraform init
$terraform apply
```

When apply completes, you should see the ALB domain name as an output:

```text

```

Open this domain name in your web browser, and you should see “Hello, World!” once again. Congrats, you now have a single endpoint, the load balancer domain name, that you can give your users, and when users hit it, the load balancer will distribute their requests across all the apps in your ASG!

## Roll Out Updates with Terraform and Auto Scaling Groups

AWS ASGs support rolling deployments through a feature called instance refresh. Our ASG module configuration already has the proper parameter for rolling updates

```hcl
provider "aws" {
  region = "us-east-2"
}

module "asg" {
  source  = "../../modules/asg"

  # ... (other params omitted) ...

  instance_refresh = {
    min_healthy_percentage = 100     #1
    max_healthy_percentage = 200     #2
    auto_rollback          = true    #3
  }
}
```

#### This code sets the following parameters:

1. min_healthy_percentage: Setting this to 100% means that the cluster will never have fewer than the desired number of instances (initially, three), even during deployment. Whereas with server orchestration you update instances in place, with VM orchestration you’ll deploy new instances, as per the next parameter.
2. max_healthy_percentage: Setting this to 200% means that to deploy updates, the cluster will deploy totally new instances, up to twice the original size of the cluster, wait for the new instances to pass health checks, and then undeploy the old instances. So if you started with three instances, you’ll go up to six instances during deployment, with three new and three old, and when the new instances pass health checks, you’ll go back to three instances by undeploying the old ones.
3. auto_rollback: If something goes wrong during deployment and the new instances fail to pass health checks, this setting will automatically initiate a rollback, putting your cluster back to its previous working condition.

### Update the app response text:

You can try rolling out a change. For example, update app.js in the packer folder (packer/sample-app/app.js) to respond with "Fundamentals of DevOps!" as shown below:

```javascript
res.end('Fundamentals of DevOps!\n');
```

### Build a new AMI:

```bash
$packer build sample-app.pkr.hcl
```

When the Packer build is complete, go back to the asg-sample module and run apply again. The module will automatically find the newly built AMI, the ASG will launch three new EC2 instances, and the ALB will start performing health checks on them. Once the new instances start to pass health checks, the ASG will undeploy the old instances, leaving you with just the three new instances running the new code. The whole process should take around five minutes.

During this deployment, the load balancer URL should always return a successful response, as this is a zero-downtime deployment. You can even check this by opening a new terminal tab and running the following Bash

```bash
$while true; do curl http://<YourLoadBalancer-IP>; done
```

This code runs curl, an HTTP client, in a loop, hitting your ALB once per second and allowing you to see the zero-downtime deployment in action. For the first couple of minutes, you should see only "Hello, World!" responses from the old instances. Then, as new instances start to pass health checks, the ALB will begin sending traffic to them, and you should see the response from the ALB alternate between Hello, World! and "Fundamentals of DevOps!" After another couple of minutes, the "Hello, World!" message will disappear, and you’ll see only "Fundamentals of DevOps!", which means all the old instances have been shut down. The output will look something like this:

```text
Hello, World!
Hello, World!
Hello, World!
Hello, World!
Hello, World!
Hello, World!
Fundamentals of DevOps!
Hello, World!
Fundamentals of DevOps!
Hello, World!
Fundamentals of DevOps!
Hello, World!
Fundamentals of DevOps!
Hello, World!
Fundamentals of DevOps!
Hello, World!
Fundamentals of DevOps!
Fundamentals of DevOps!
Fundamentals of DevOps!
Fundamentals of DevOps!
Fundamentals of DevOps!
Fundamentals of DevOps!
Fundamentals of DevOps!
Fundamentals of DevOps!
```

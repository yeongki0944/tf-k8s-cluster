# outputs.tf - Terraform Outputs

#===========================================
# Cluster Information
#===========================================

output "cluster_info" {
  description = "Basic cluster information"
  value = {
    cluster_name = var.cluster_name
    cluster_id   = local.cluster_id
    aws_region   = var.aws_region
    timezone     = var.timezone
  }
}

#===========================================
# VPC and Network Information
#===========================================

output "vpc_info" {
  description = "VPC and networking information"
  value = {
    vpc_id         = aws_vpc.main.id
    vpc_cidr       = aws_vpc.main.cidr_block
    igw_id         = aws_internet_gateway.main.id
    route_table_id = aws_route_table.public.id
  }
}

output "subnet_info" {
  description = "Subnet information"
  value = {
    public_subnet_ids = aws_subnet.public[*].id
    public_subnet_cidrs = aws_subnet.public[*].cidr_block
    availability_zones = aws_subnet.public[*].availability_zone
  }
}

output "security_group_info" {
  description = "Security group information"
  value = {
    master_sg_id = aws_security_group.k8s_master.id
    worker_sg_id = aws_security_group.k8s_worker.id
  }
}

#===========================================
# Key Pair Information
#===========================================

output "key_pair_info" {
  description = "SSH key pair information"
  value = {
    key_name         = aws_key_pair.k8s_key.key_name
    key_fingerprint  = aws_key_pair.k8s_key.fingerprint
    private_key_file = "${path.module}/${var.cluster_name}-key.pem"
  }
}

#===========================================
# EC2 Instance Information
#===========================================

output "master_node_info" {
  description = "Kubernetes master node information"
  value = {
    instance_id          = aws_instance.k8s_master.id
    instance_type        = aws_instance.k8s_master.instance_type
    public_ip           = aws_instance.k8s_master.public_ip
    private_ip          = aws_instance.k8s_master.private_ip
    public_dns          = aws_instance.k8s_master.public_dns
    availability_zone   = aws_instance.k8s_master.availability_zone
    subnet_id           = aws_instance.k8s_master.subnet_id
    security_groups     = aws_instance.k8s_master.vpc_security_group_ids
  }
}

output "worker_nodes_info" {
  description = "Kubernetes worker nodes information"
  value = [
    for i, instance in aws_instance.k8s_workers : {
      worker_number       = i + 1
      instance_id         = instance.id
      instance_type       = instance.instance_type
      public_ip          = instance.public_ip
      private_ip         = instance.private_ip
      public_dns         = instance.public_dns
      availability_zone  = instance.availability_zone
      subnet_id          = instance.subnet_id
      security_groups    = instance.vpc_security_group_ids
    }
  ]
}

#===========================================
# Parameter Store Information
#===========================================

output "parameter_store_info" {
  description = "Parameter Store information for cluster management"
  value = {
    join_command_parameter = aws_ssm_parameter.k8s_join_command.name
    parameter_arn         = aws_ssm_parameter.k8s_join_command.arn
  }
}

#===========================================
# SSH Connection Commands
#===========================================

output "ssh_commands" {
  description = "SSH connection commands (copy and paste ready)"
  value = {
    master = "ssh -i ${var.cluster_name}-key.pem ec2-user@${aws_instance.k8s_master.public_ip}"
    workers = [
      for i, instance in aws_instance.k8s_workers :
      "ssh -i ${var.cluster_name}-key.pem ec2-user@${instance.public_ip}  # worker-${i + 1}"
    ]
  }
}

output "ssh_config_block" {
  description = "SSH config block for ~/.ssh/config file"
  value = <<-EOT
    # Kubernetes Cluster: ${var.cluster_name}
    Host ${var.cluster_name}-master
        HostName ${aws_instance.k8s_master.public_ip}
        User ec2-user
        IdentityFile ${path.module}/${var.cluster_name}-key.pem
        
    %{for i, instance in aws_instance.k8s_workers~}
    Host ${var.cluster_name}-worker-${i + 1}
        HostName ${instance.public_ip}
        User ec2-user
        IdentityFile ${path.module}/${var.cluster_name}-key.pem
        
    %{endfor~}
  EOT
}

#===========================================
# Cluster Access Information
#===========================================

output "cluster_access" {
  description = "Instructions for accessing the Kubernetes cluster"
  value = <<-EOT
    
    ================================================================
    🚀 Kubernetes Cluster: ${var.cluster_name} is being deployed!
    ================================================================
    
    📋 CLUSTER INFORMATION:
    - Cluster ID: ${local.cluster_id}
    - Master Node: ${aws_instance.k8s_master.public_ip}
    - Worker Nodes: ${join(", ", aws_instance.k8s_workers[*].public_ip)}
    - SSH Key: ${var.cluster_name}-key.pem
    
    🔧 SETUP PROGRESS:
    1. Master node initialization: ~5-7 minutes
    2. Worker nodes joining: ~3-5 minutes each
    3. Total estimated time: ~10-15 minutes
    
    📡 SSH ACCESS:
    ssh -i ${var.cluster_name}-key.pem ec2-user@${aws_instance.k8s_master.public_ip}
    
    🎯 KUBECTL SETUP (run on master node):
    kubectl get nodes
    kubectl get pods -n kube-system
    
    📝 LOG MONITORING:
    Master: tail -f /var/log/k8s-master-${local.cluster_id}.log
    Worker: tail -f /var/log/k8s-worker-${local.cluster_id}.log
    
    🔍 PARAMETER STORE:
    aws ssm get-parameter --name "${aws_ssm_parameter.k8s_join_command.name}" --with-decryption
    
    🧹 CLEANUP:
    terraform destroy
    
    ================================================================
    
  EOT
}

#===========================================
# Quick Reference Commands
#===========================================

output "useful_commands" {
  description = "Useful commands for cluster management"
  value = {
    check_cluster_status = [
      "kubectl get nodes",
      "kubectl get pods -n kube-system",
      "kubectl cluster-info"
    ]
    
    check_logs = [
      "# Master node logs",
      "tail -f /var/log/k8s-master-${local.cluster_id}.log",
      "tail -f /var/log/cloud-init-output.log",
      "",
      "# Worker node logs", 
      "tail -f /var/log/k8s-worker-${local.cluster_id}.log",
      "tail -f /var/log/cloud-init-output.log"
    ]
    
    troubleshooting = [
      "# Check join token",
      "aws ssm get-parameter --name '${aws_ssm_parameter.k8s_join_command.name}' --with-decryption",
      "",
      "# Check kubelet status",
      "sudo systemctl status kubelet",
      "",
      "# Check containerd status", 
      "sudo systemctl status containerd",
      "",
      "# Restart services if needed",
      "sudo systemctl restart kubelet",
      "sudo systemctl restart containerd"
    ]
  }
}

#===========================================
# Cost Information
#===========================================

output "estimated_cost" {
  description = "Estimated hourly cost breakdown (USD)"
  value = {
    master_node_hourly  = "~$0.0416 (t3.medium in ap-northeast-2)"
    worker_nodes_hourly = "~$0.0624 (3 x t3.small in ap-northeast-2)"
    total_hourly       = "~$0.104"
    daily_estimated    = "~$2.50"
    monthly_estimated  = "~$75.00"
    note               = "Costs may vary by region and actual usage. EBS storage additional."
  }
}

#===========================================
# Resource Summary
#===========================================

output "resource_summary" {
  description = "Summary of all created resources"
  value = {
    total_ec2_instances = 1 + var.worker_count
    vpc_resources = {
      vpc        = 1
      subnets    = length(var.public_subnet_cidrs)
      igw        = 1
      route_tables = 1
    }
    security_groups = 2
    iam_resources = {
      roles     = 1
      policies  = 1
      profiles  = 1
    }
    ssm_parameters = 1
    key_pairs     = 1
  }
}
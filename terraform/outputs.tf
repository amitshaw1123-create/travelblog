output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer (your app URL)"
  value       = "http://${aws_lb.wanderlog.dns_name}"
}

output "ecr_repository_url" {
  description = "URL of the ECR repository"
  value       = aws_ecr_repository.wanderlog.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.wanderlog.name
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.wanderlog.name
}

output "efs_id" {
  description = "ID of the EFS filesystem"
  value       = aws_efs_file_system.wanderlog.id
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

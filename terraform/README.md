# WanderLog AWS Infrastructure (Terraform)

This directory contains Terraform configuration to provision all AWS resources needed to run WanderLog on ECS Fargate.

## What gets created

| Resource | Purpose |
|---|---|
| **ECR Repository** | Stores Docker images |
| **ECS Cluster** | Runs containerized app |
| **ECS Service** | Manages task count, health checks |
| **Application Load Balancer** | Public HTTP endpoint |
| **EFS Filesystem** | Persistent storage for DB and uploads |
| **Security Groups** | Network access control |
| **IAM Roles** | Permissions for ECS tasks |
| **Secrets Manager** | Stores SECRET_KEY and ANTHROPIC_API_KEY |

**Total monthly cost:** ~$15–20 USD (Fargate + ALB + EFS)

---

## Prerequisites

1. **AWS CLI** installed and configured
   ```bash
   aws configure
   # Enter your AWS Access Key ID, Secret Access Key, Region
   ```

2. **Terraform** installed (v1.0+)
   - Download from https://www.terraform.io/downloads
   - Or: `brew install terraform` (macOS) / `choco install terraform` (Windows)

3. **Docker** installed (for building the image)

---

## Step-by-step deployment

### 1. Create `terraform.tfvars`
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
aws_region        = "us-east-1"
secret_key        = "your-64-char-hex-string"  # Generate: python3 -c "import secrets; print(secrets.token_hex(32))"
anthropic_api_key = "sk-ant-your-key-here"
```

### 2. Initialize Terraform
```bash
terraform init
```

### 3. Preview the infrastructure
```bash
terraform plan
```
Review the 20+ resources that will be created.

### 4. Create the infrastructure
```bash
terraform apply
```
Type `yes` when prompted. Takes ~5 minutes.

**Save the outputs** — you'll need them for GitHub Actions:
```
alb_dns_name       = http://wanderlog-alb-123456.us-east-1.elb.amazonaws.com
ecr_repository_url = 123456789012.dkr.ecr.us-east-1.amazonaws.com/wanderlog
ecs_cluster_name   = wanderlog-cluster
ecs_service_name   = wanderlog-service
```

### 5. Build and push the first image

The ECS service expects an image to exist in ECR. Push one manually:

```bash
# Log in to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <ECR_REPOSITORY_URL>

# Build and tag
docker build -t <ECR_REPOSITORY_URL>:latest ..

# Push
docker push <ECR_REPOSITORY_URL>:latest
```

Replace `<ECR_REPOSITORY_URL>` with the value from `terraform output ecr_repository_url`.

### 6. Wait for the service to stabilize

```bash
aws ecs wait services-stable \
  --cluster wanderlog-cluster \
  --services wanderlog-service \
  --region us-east-1
```

Once stable, open the ALB DNS in your browser:
```
http://wanderlog-alb-123456.us-east-1.elb.amazonaws.com
```

---

## GitHub Actions setup

After Terraform succeeds, configure GitHub Actions to auto-deploy on every push.

### Add these secrets to your GitHub repo

**Settings → Secrets and variables → Actions → New repository secret:**

| Secret | Value | Where to get it |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Your IAM access key | AWS IAM Console |
| `AWS_SECRET_ACCESS_KEY` | Your IAM secret key | AWS IAM Console |
| `AWS_REGION` | `us-east-1` (or your region) | `terraform output aws_region` |
| `ECR_REPOSITORY` | `wanderlog` | `terraform output ecr_repository_url` (last part) |
| `ECS_CLUSTER` | `wanderlog-cluster` | `terraform output ecs_cluster_name` |
| `ECS_SERVICE` | `wanderlog-service` | `terraform output ecs_service_name` |
| `SECRET_KEY` | Same as in `terraform.tfvars` | (copy from your tfvars) |
| `ANTHROPIC_API_KEY` | Same as in `terraform.tfvars` | (copy from your tfvars) |

### Test the workflow

```bash
git push origin main
```

GitHub Actions will:
1. Build the Docker image
2. Push to ECR
3. Update the ECS task definition
4. Deploy to ECS (zero-downtime rolling update)

---

## Useful commands

```bash
# Show all outputs
terraform output

# Show just the app URL
terraform output alb_dns_name

# Update infrastructure (e.g., after changing task CPU)
terraform apply

# Destroy everything (WARNING: deletes all data!)
terraform destroy
```

### View logs
```bash
aws logs tail /ecs/wanderlog --follow --region us-east-1
```

### Force new deployment (pulls latest image)
```bash
aws ecs update-service \
  --cluster wanderlog-cluster \
  --service wanderlog-service \
  --force-new-deployment \
  --region us-east-1
```

---

## Troubleshooting

### Issue: ECS task keeps restarting

Check CloudWatch Logs:
```bash
aws logs tail /ecs/wanderlog --follow --region us-east-1
```

Common causes:
- Missing secrets in Secrets Manager → check `terraform apply` succeeded
- Image doesn't exist in ECR → push an image manually first
- Health check failing → ensure container listens on port 8000

### Issue: ALB returns 503

The target group has no healthy targets. Check:
```bash
aws ecs describe-services \
  --cluster wanderlog-cluster \
  --services wanderlog-service \
  --region us-east-1
```

Look for `runningCount` > 0.

### Issue: Can't push to ECR

Re-authenticate:
```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $(terraform output -raw ecr_repository_url | cut -d/ -f1)
```

---

## Clean up

To delete all resources and stop incurring charges:

```bash
terraform destroy
```

Type `yes` when prompted. Takes ~10 minutes.

**WARNING:** This deletes:
- The EFS filesystem (your database and uploads)
- All Docker images in ECR
- All CloudWatch logs

If you want to preserve data, back up the EFS filesystem first.

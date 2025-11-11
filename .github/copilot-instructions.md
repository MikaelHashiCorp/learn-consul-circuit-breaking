# Copilot Instructions: Learn Consul Circuit Breaking

## Project Overview
This is a HashiCorp tutorial companion repository demonstrating Consul service mesh circuit breaking on AWS EKS. It provisions infrastructure with Terraform, deploys Consul, and sets up the HashiCups demo application to showcase circuit breaker functionality.

## Architecture
- **Infrastructure**: AWS EKS cluster on custom VPC with public/private subnets
- **Service Mesh**: Consul deployed via Helm with ACLs, TLS, and transparent proxy enabled
- **Demo App**: HashiCups microservices demonstrating service-to-service communication and circuit breaking

### Service Dependency Chain
The HashiCups application follows this call chain:
```
traffic-generator/api-gateway → nginx → frontend → public-api → product-api → product-api-db
                                                              └→ payments
```

- **nginx**: Entry point with circuit breaker config (`servicedefaults-nginx.yaml`)
- **frontend**: User-facing service
- **public-api**: API gateway that fans out to multiple backends
- **product-api/payments**: Backend services that can fail
- **traffic-generator**: Fortio-based load generator for testing circuit breakers

### Circuit Breaking Tutorial Flow
1. **Normal state**: All services healthy, traffic flows through entire chain
2. **Trip circuit breaker**: Apply `failing-service-public-api.yaml` to disable health checks on public-api upstreams
3. **Observe cascade**: When product-api or payments fail, circuit breaker in nginx detects failures and ejects unhealthy instances
4. **Recovery**: Circuit breaker automatically re-enables instances after `baseEjectionTime` (10s)

Key circuit breaker settings in `servicedefaults-nginx.yaml`:
- `maxFailures: 3` - Trip after 3 consecutive failures
- `enforcingConsecutive5xx: 100` - Enforce circuit breaking on all 5xx errors
- `baseEjectionTime: "10s"` - Keep instance ejected for 10 seconds

## Critical Patterns

### AWS Authentication for Terraform
This project requires HashiCorp-specific AWS authentication via `doormat`:
```bash
eval $(doormat aws export --account aws_mikael.sikora_test) ; curl https://ipinfo.io/ip ; echo ; aws sts get-caller-identity --output table
```
**CRITICAL: Always authenticate before running Terraform commands.** Standard AWS credentials won't work.

**Terminal Session Management**:
- **NEVER open new terminals when running commands** - credentials don't transfer
- **Always reuse the same authenticated terminal** for all AWS/Terraform/kubectl commands
- **If you must open a new terminal**, authenticate FIRST with the command above before any AWS operations
- Each terminal session requires separate authentication - credentials don't persist across terminals

### Terraform Module Dependencies
The EKS module (v19.20.0) creates resources that require careful provider configuration to avoid circular dependencies:

```terraform
# ✅ CORRECT: Use module outputs directly
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec { ... }  # Dynamic token via AWS CLI
}

# ❌ WRONG: Don't use data sources with depends_on - causes cycles
data "aws_eks_cluster" "cluster" {
  depends_on = [module.eks]  # Creates circular dependency
}
```

**Pattern**: Always use `module.eks.cluster_endpoint` and `module.eks.cluster_certificate_authority_data` outputs instead of `data.aws_eks_cluster` data sources in provider configurations.

### Provider Authentication Method
All Kubernetes-related providers (kubernetes, helm, kubectl) must use AWS CLI exec authentication for token refresh:
```terraform
exec {
  api_version = "client.authentication.k8s.io/v1beta1"
  command     = "aws"
  args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
}
```
Static tokens from `aws_eks_cluster_auth` data source expire during long-running operations.

### EKS Version Requirements
AWS regularly deprecates older Kubernetes versions. As of Nov 2025, minimum supported version is 1.28. Always use the latest stable version (currently 1.31) in `eks-cluster.tf`:
```terraform
cluster_version = "1.31"  # Not 1.27 or earlier
```

### Storage Class Configuration
Consul servers require persistent storage on EKS. The `consul-helm/values.yaml` must specify storage class:
```yaml
server:
  enabled: true
  replicas: 3
  storageClass: gp2  # Required for EKS - don't omit this
```
Without this, PVCs remain in "Pending" state and pods can't schedule.

### Kubernetes Service Deployment Pattern
Services are deployed via kubectl provider using a directory glob pattern:
```terraform
data "kubectl_path_documents" "docs" {
  pattern = "${path.module}/k8s-services/service-*.yaml"
}
```
All service manifests in `k8s-services/` follow this naming convention and include ServiceDefaults and ServiceIntentions for Consul integration.

## Development Workflow

### Initial Deployment
```bash
# 1. Authenticate (required in each terminal session - use SAME terminal for all commands)
eval $(doormat aws export --account aws_mikael.sikora_test) ; curl https://ipinfo.io/ip ; echo ; aws sts get-caller-identity --output table

# 2. Deploy infrastructure (in SAME terminal as authentication)
terraform init
terraform apply -auto-approve

# 3. Configure kubectl (in SAME terminal)
aws eks update-kubeconfig --region us-east-2 --name $(terraform output -raw cluster_name)
```

### Cleanup and Rebuild
If Helm releases fail or resources are in inconsistent state:
```bash
# Run ALL commands in the SAME terminal session
eval $(doormat aws export --account aws_mikael.sikora_test) ; curl https://ipinfo.io/ip ; echo ; aws sts get-caller-identity --output table
terraform destroy -auto-approve
terraform apply -auto-approve
```

**Don't manually delete Kubernetes resources** - let Terraform manage lifecycle to avoid state drift.

**Important**: All these commands must run in the same terminal where you authenticated. Opening a new terminal requires re-authentication before running any command.

### Handling State Drift (Manual AWS Console Changes)
If infrastructure was modified outside Terraform (e.g., via AWS Console), the state becomes out of sync:

```bash
# Option 1: Refresh state to match current AWS reality
terraform refresh

# Then retry destroy
terraform destroy -auto-approve

# Option 2: Target specific stuck resources
terraform destroy -target=module.eks -auto-approve
terraform destroy -target=module.vpc -auto-approve

# Option 3: Force remove from state (if resource already deleted in AWS)
terraform state rm <resource_address>

# Option 4: Nuclear option - reset state (requires manual AWS cleanup)
rm terraform.tfstate terraform.tfstate.backup
# Then manually delete resources in AWS Console
```

**Best practice**: Always use Terraform to modify infrastructure. Manual console changes break state tracking and cause destroy/apply failures.

### Debugging Failed Deployments
```bash
# IMPORTANT: Run all debugging commands in the same authenticated terminal
# If you open a new terminal, authenticate first:
eval $(doormat aws export --account aws_mikael.sikora_test) ; curl https://ipinfo.io/ip ; echo ; aws sts get-caller-identity --output table

# Check pod status
kubectl get pods -n consul
kubectl describe pod <pod-name> -n consul

# Check PVC issues
kubectl get pvc -n consul

# Verify storage class exists
kubectl get storageclass
```

## Key Files

- `eks-cluster.tf` - EKS cluster config, include cluster_version and data source definitions
- `providers.tf` - Provider authentication with exec blocks for dynamic tokens
- `consul-helm/values.yaml` - Consul configuration including required storageClass
- `eks-services.tf` - Pattern for batch-deploying K8s manifests via kubectl provider
- `k8s-services/` - All service manifests with Consul annotations and ServiceDefaults

## Known Issues

- **Circular dependencies**: Avoid using `data.aws_eks_cluster` with `depends_on` in provider configs
- **Token expiration**: Static tokens from data sources fail on long Helm deployments - use exec blocks
- **PVC pending**: Missing storage class causes persistent volume issues - always set `storageClass: gp2`
- **Authentication scope**: doormat credentials don't persist across terminal sessions - **ALWAYS reuse the same terminal** or re-authenticate with full command in new terminals
- **Terminal management**: Opening new terminals causes authentication errors - keep using the same authenticated terminal for all operations
- **State drift**: Manual changes via AWS Console cause Terraform state to become out of sync - use `terraform refresh` to resync, or `terraform state rm` to remove deleted resources from state

#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }

CLUSTER_NAME=${CLUSTER_NAME:-microservices-cluster}
AWS_REGION=${AWS_REGION:-eu-central-1}
NAMESPACE=${NAMESPACE:-microservices}
SKIP_TF=${SKIP_TF:-false}
AUTO_APPROVE=${AUTO_APPROVE:-false}

cleanup() {
  log_warn "Script interrupted."
}
trap cleanup SIGINT SIGTERM

check_deps() {
  local missing=0
  for cmd in kubectl aws terraform; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "$cmd not found. Please install it."
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then exit 1; fi
  log_info "✓ All dependencies available"
}

delete_k8s_resources() {
  log_step "Phase 1: Remove Kubernetes Resources"

  if ! kubectl cluster-info &>/dev/null 2>&1; then
    log_warn "Cannot connect to cluster. Skipping K8s cleanup."
    return
  fi

  if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    log_info "Deleting namespace $NAMESPACE (this may take a moment)..."
    kubectl delete namespace "$NAMESPACE" --timeout=120s 2>/dev/null || true
    while kubectl get namespace "$NAMESPACE" &>/dev/null; do
      sleep 3
    done
    log_info "✓ Namespace deleted"
  else
    log_info "Namespace $NAMESPACE not found, skipping"
  fi

  log_info "Cleaning remaining resources in kube-system..."
  kubectl delete secret ecr-secret -n kube-system 2>/dev/null || true
  kubectl delete deployment aws-load-balancer-controller -n kube-system 2>/dev/null || true
  kubectl delete serviceaccount aws-load-balancer-controller -n kube-system 2>/dev/null || true

  if kubectl get namespace argocd &>/dev/null; then
    log_info "Deleting ArgoCD resources..."
    kubectl delete application -n argocd --all 2>/dev/null || true
    sleep 5
    # Remove application finalizers to prevent deletion hangs
    kubectl get application -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | xargs -r -I {} kubectl patch application {} -n argocd --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    sleep 5
    helm uninstall argocd -n argocd 2>/dev/null || true
    kubectl delete namespace argocd --timeout=120s 2>/dev/null || true
    while kubectl get namespace argocd &>/dev/null; do
      sleep 3
    done
    log_info "✓ ArgoCD removed"
  fi

  if kubectl get namespace monitoring &>/dev/null; then
    log_info "Deleting monitoring namespace..."
    kubectl delete application prometheus -n argocd 2>/dev/null || true
    sleep 3
    kubectl delete namespace monitoring --timeout=120s 2>/dev/null || true
    while kubectl get namespace monitoring &>/dev/null; do
      sleep 3
    done
    log_info "✓ Monitoring namespace deleted"
  fi
}

destroy_terraform() {
  log_step "Phase 2: Destroy Terraform Infrastructure"

  if [[ ! -d "$SCRIPT_DIR/terraform/.terraform" ]]; then
    log_info "Terraform not initialized, skipping"
    return
  fi

  cd "$SCRIPT_DIR/terraform"

  # Migrate backend to local to prevent S3 bucket lock/deletion deadlock
  log_info "Checking backend configuration..."
  if grep -q 'backend "s3"' backend.tf; then
    log_warn "Active S3 backend detected. Migrating state to local to allow clean resource deletion..."
    cp backend.tf backend.tf.backup
    cat << 'EOF' > backend.tf
# terraform {
#    backend "s3" {
#      bucket         = "google-microservices-terraform-state"
#      key            = "microservices/terraform.tfstate"
#      region         = "eu-central-1"
#      encrypt        = true
#      dynamodb_table = "terraform-state-lock"
#    }
#  }
EOF
    terraform init -migrate-state -force-copy -lock=false || true
  fi

  # Empty the S3 bucket so it can be deleted by Terraform
  local bucket_name="google-microservices-terraform-state"
  if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
    log_info "Emptying S3 bucket $bucket_name before destruction..."
    local versions
    versions=$(aws s3api list-object-versions --bucket "$bucket_name" --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo "")
    if [[ -n "$versions" && "$versions" != "null" && "$versions" != "{\"Objects\":null}" ]]; then
      aws s3api delete-objects --bucket "$bucket_name" --delete "$versions" >/dev/null 2>&1 || true
    fi
    local markers
    markers=$(aws s3api list-object-versions --bucket "$bucket_name" --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo "")
    if [[ -n "$markers" && "$markers" != "null" && "$markers" != "{\"Objects\":null}" ]]; then
      aws s3api delete-objects --bucket "$bucket_name" --delete "$markers" >/dev/null 2>&1 || true
    fi
  fi

  local approve_flag=""
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    approve_flag="-auto-approve"
    log_info "Auto-approve enabled"
  else
    log_warn "Plan to destroy shown above. Re-run with AUTO_APPROVE=true to execute."
  fi

  terraform destroy $approve_flag

  # Restore backend.tf
  if [[ -f backend.tf.backup ]]; then
    mv backend.tf.backup backend.tf
  fi

  cd "$SCRIPT_DIR"
  log_info "✓ Infrastructure destroyed"
}

main() {
  echo -e "${RED}═══════════════════════════════════════════${NC}"
  echo -e "${RED}  DESTROY — This removes all resources${NC}"
  echo -e "${RED}═══════════════════════════════════════════${NC}"
  echo ""
  echo "  Cluster:   $CLUSTER_NAME"
  echo "  Region:    $AWS_REGION"
  echo "  Namespace: $NAMESPACE"
  echo ""

  if [[ "$AUTO_APPROVE" != "true" ]]; then
    echo -e "${YELLOW}Press Ctrl+C within 5 seconds to cancel...${NC}"
    sleep 5
  fi

  check_deps
  delete_k8s_resources

  if [[ "$SKIP_TF" != "true" ]]; then
    destroy_terraform
  fi

  log_info "Teardown complete"
}

main

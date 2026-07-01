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
IMAGE_TAG=${IMAGE_TAG:-latest}
TF_ACTION=${TF_ACTION:-apply}           # apply or plan-only
SKIP_TF=${SKIP_TF:-false}
SKIP_K8S=${SKIP_K8S:-false}

cleanup() {
  log_warn "Script interrupted. Cleaning up..."
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

run_terraform() {
  log_step "Phase 1: Terraform Infrastructure"
  cd "$SCRIPT_DIR/terraform"

  if [[ ! -d .terraform ]]; then
    log_info "Initializing Terraform..."
    terraform init
  fi

  if [[ "$TF_ACTION" == "plan-only" ]]; then
    terraform plan -out=tfplan
    log_info "Review the plan above, then run again with TF_ACTION=apply"
    return
  fi

  terraform apply -auto-approve

  log_info "Configuring kubectl..."
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --kubeconfig /dev/stdout 2>/dev/null \
    | kubectl apply -f - 2>/dev/null || true
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME" >/dev/null 2>&1 || true

  cd "$SCRIPT_DIR"
  log_info "✓ Infrastructure ready"
}

validate_manifests() {
  log_step "Phase 2: Validate Kustomize Manifests"
  if ! kubectl kustomize "$SCRIPT_DIR/k8s/base" >/dev/null; then
    log_error "Kustomize validation failed"
    exit 1
  fi
  log_info "✓ Manifests valid"
}

check_cluster() {
  log_step "Phase 3: Cluster Health Check"

  if ! kubectl cluster-info &>/dev/null; then
    log_error "Cannot connect to cluster. Run: aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME"
    exit 1
  fi

  local ready_nodes
  ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/ {count++} END {print count+0}')
  if [[ "$ready_nodes" -lt 1 ]]; then
    log_error "No Ready nodes found"
    exit 1
  fi
  log_info "✓ Cluster healthy ($ready_nodes Ready node(s))"
}

verify_ecr_images() {
  log_info "Verifying ECR images (tag: $IMAGE_TAG)..."

  local services=(
    adservice cartservice checkoutservice currencyservice emailservice
    frontend paymentservice productcatalogservice recommendationservice shippingservice
  )
  local missing=0

  for svc in "${services[@]}"; do
    if ! aws ecr describe-images --region "$AWS_REGION" --repository-name "$svc" \
         --image-ids "imageTag=$IMAGE_TAG" >/dev/null 2>&1; then
      log_error "Missing: $svc:$IMAGE_TAG"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    log_info "Build and push images with: docker compose build && ./push-images.sh"
    exit 1
  fi
  log_info "✓ All images present"
}

deploy_microservices() {
  log_step "Phase 4: Deploy Microservices"

  kubectl apply -f "$SCRIPT_DIR/k8s/base/namespace.yaml" 2>/dev/null || true

  log_info "Deploying via Kustomize..."
  kubectl apply -k "$SCRIPT_DIR/k8s/base/"

  log_info "Waiting for rollouts..."
  local deployments
  deployments=$(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  for dep in $deployments; do
    log_info "  Waiting for $dep..."
    kubectl rollout status "deployment/$dep" -n "$NAMESPACE" --timeout=5m 2>/dev/null || log_warn "  Timeout waiting for $dep"
  done
}

print_summary() {
  log_step "Deployment Summary"
  echo ""
  echo "Namespace:  $NAMESPACE"
  echo "Cluster:    $CLUSTER_NAME"
  echo "Region:     $AWS_REGION"
  echo "Image tag:  $IMAGE_TAG"
  echo ""
  echo "Deployments:"
  kubectl get deployments -n "$NAMESPACE" -o wide 2>/dev/null || echo "  (none)"
  echo ""
  echo "Pods:"
  kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "  (none)"
  echo ""
  echo "Services:"
  kubectl get services -n "$NAMESPACE" 2>/dev/null || echo "  (none)"

  local frontend_url
  frontend_url=$(kubectl get svc frontend-external -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [[ -n "$frontend_url" ]]; then
    echo -e "\n${GREEN}Frontend:${NC} http://$frontend_url"
  fi

  echo -e "\n${GREEN}To configure kubectl:${NC}"
  echo "  aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME"
}

main() {
  echo -e "${CYAN}═══════════════════════════════════════════${NC}"
  echo -e "${CYAN}  Microservices Deployment${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════${NC}"
  echo ""

  check_deps

  if [[ "$SKIP_TF" != "true" ]]; then
    run_terraform
  fi

  if [[ "$SKIP_K8S" != "true" ]]; then
    validate_manifests
    check_cluster
    verify_ecr_images
    deploy_microservices
    print_summary
  fi

  log_info "Done"
}

main

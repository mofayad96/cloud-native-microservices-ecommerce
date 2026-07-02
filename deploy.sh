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

install_lb_controller() {
  log_step "Phase 3.5: Install AWS Load Balancer Controller"

  if kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
    log_info "AWS Load Balancer Controller already installed, skipping"
    return
  fi

  helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
  helm repo update eks 2>/dev/null

  local role_arn vpc_id
  role_arn=$(cd "$SCRIPT_DIR/terraform" && terraform output -raw lb_controller_role_arn 2>/dev/null)
  vpc_id=$(cd "$SCRIPT_DIR/terraform" && terraform output -raw vpc_id 2>/dev/null)

  if [[ -z "$role_arn" ]]; then
    log_error "Could not get LB Controller IAM role ARN from Terraform output"
    return 1
  fi

  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$role_arn" \
    --set region="$AWS_REGION" \
    --set vpcId="$vpc_id"

  log_info "Waiting for LBC to be ready..."
  kubectl rollout status deployment -n kube-system aws-load-balancer-controller --timeout=180s
  log_info "✓ AWS Load Balancer Controller ready"
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

install_argocd() {
  log_step "Phase 4: Install ArgoCD"

  if kubectl get deployment -n argocd argocd-server &>/dev/null; then
    log_info "ArgoCD already installed"
  else
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --set server.service.type=ClusterIP
    log_info "Waiting for ArgoCD to be ready..."
    kubectl rollout status deployment -n argocd argocd-server --timeout=180s
  fi
}

deploy_shared_resources() {
  log_step "Phase 5: Deploy Shared Resources"

  kubectl apply -f "$SCRIPT_DIR/k8s/base/namespace.yaml" 2>/dev/null || true
  kubectl apply -f "$SCRIPT_DIR/k8s/base/common-config.yaml" 2>/dev/null || true
  kubectl create configmap -n "$NAMESPACE" microservices-env \
    --from-literal=AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
    --from-literal=AWS_REGION="$AWS_REGION" \
    --from-literal=CLUSTER_NAME="$CLUSTER_NAME" \
    --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
}

deploy_argocd_apps() {
  log_step "Phase 6: Apply ArgoCD Applications"

  kubectl apply -f "$SCRIPT_DIR/k8s/parent-argocd.yaml"
  kubectl apply -f "$SCRIPT_DIR/k8s/apps/argo-monitoring-addons.yaml"

  log_info "Waiting for ArgoCD to sync microservices..."
  for i in $(seq 1 24); do
    sleep 15
    local unhealthy
    unhealthy=$(kubectl get application -n argocd --no-headers 2>/dev/null | grep -vc "Healthy" || true)
    if [[ "$unhealthy" -le 2 ]]; then
      log_info "✓ All applications healthy"
      break
    fi
    log_info "  Waiting... ($unhealthy apps not healthy)"
  done
}

wait_for_monitoring() {
  log_step "Phase 7: Wait for Monitoring Stack"

  if ! kubectl get application -n argocd prometheus &>/dev/null; then
    log_info "Prometheus app not yet discovered by ArgoCD, skipping"
    return
  fi

  log_info "Waiting for Prometheus/Grafana pods to be ready..."
  for i in $(seq 1 18); do
    sleep 10
    local ready
    ready=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -c "Running" || true)
    local total
    total=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | wc -l || true)
    if [[ "$total" -gt 0 ]] && [[ "$ready" -eq "$total" ]]; then
      log_info "✓ All $total monitoring pods running"
      return
    fi
    log_info "  Waiting... ($ready/$total pods running)"
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

  local frontend_url ingress_url
  frontend_url=$(kubectl get svc frontend-service -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [[ -n "$frontend_url" ]]; then
    echo -e "\n${GREEN}Frontend (LoadBalancer):${NC} http://$frontend_url:8080"
  fi
  ingress_url=$(kubectl get ingress frontend-ingress -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [[ -n "$ingress_url" ]]; then
    echo -e "\n${GREEN}Frontend (ALB Ingress):${NC} http://$ingress_url"
  fi

  echo -e "\n${GREEN}ArgoCD UI:${NC} kubectl port-forward svc/argocd-server -n argocd 8080:443"
  echo -e "${GREEN}ArgoCD Password:${NC} kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"

  if kubectl get ns monitoring &>/dev/null; then
    echo -e "\n${GREEN}Grafana:${NC} kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"
    echo -e "${GREEN}Grafana Password:${NC} admin / admin123"
    echo -e "${GREEN}Prometheus:${NC} kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090"

    if kubectl get configmap -n monitoring dash-overview &>/dev/null; then
      echo -e "\n${GREEN}Custom Dashboards:${NC}"
      echo -e "  ${GREEN}• Microservices Golden Signals${NC} (UID: microservices-golden-signals)"
      echo -e "  ${GREEN}• Service Detail${NC} (UID: service-detail)"
      echo -e "  ${GREEN}• OTEL Pipeline Health${NC} (UID: otel-pipeline-health)"
    fi
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
    install_lb_controller
    verify_ecr_images
    install_argocd
    deploy_shared_resources
    deploy_argocd_apps
    wait_for_monitoring
    print_summary
  fi

  log_info "Done"
}

main

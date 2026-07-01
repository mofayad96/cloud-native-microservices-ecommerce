#!/bin/bash
# Complete deployment script for microservices to EKS
# This script automates the deployment process

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-microservices-cluster}
AWS_REGION=${AWS_REGION:-eu-central-1}
NAMESPACE="microservices"
COMPUTE_MODE=${COMPUTE_MODE:-ec2}
IMAGE_TAG=${IMAGE_TAG:-latest}
USE_IRSA_FOR_ECR=${USE_IRSA_FOR_ECR:-false}
IRSA_ECR_ROLE_ARN=${IRSA_ECR_ROLE_ARN:-}

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl."
        exit 1
    fi
    
    # Check aws cli
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install AWS CLI."
        exit 1
    fi
    
    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please configure kubectl."
        exit 1
    fi
    
    log_info "✓ All prerequisites met"
}

validate_manifest_schema() {
    log_info "Validating Kustomize manifests..."

    if ! kubectl kustomize "$SCRIPT_DIR/base" >/dev/null; then
        log_error "Kustomize validation failed for $SCRIPT_DIR/base"
        exit 1
    fi

    log_info "✓ Kustomize manifests are valid"
}

enforce_compute_path() {
    log_info "Enforcing single compute path..."

    if [[ "$COMPUTE_MODE" != "ec2" ]]; then
        log_error "Unsupported COMPUTE_MODE='$COMPUTE_MODE'. This deployment is configured for EC2 node groups only."
        exit 1
    fi

    log_info "✓ Using EC2 node groups compute path"
}

check_compute_health() {
    log_info "Checking EC2 node-group readiness..."

    local ready_nodes
    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/ {count++} END {print count+0}')

    if [[ "$ready_nodes" -lt 1 ]]; then
        log_error "No Ready nodes found. Aborting deployment."
        kubectl get nodes || true
        exit 1
    fi

    log_info "✓ Node readiness confirmed ($ready_nodes Ready node(s))"
}

verify_ecr_images() {
    log_info "Verifying ECR image tags exist (tag: $IMAGE_TAG)..."

    local services=(
        adservice
        cartservice
        checkoutservice
        currencyservice
        emailservice
        frontend
        paymentservice
        productcatalogservice
        recommendationservice
        shippingservice
    )

    local missing=0
    for service in "${services[@]}"; do
        if ! aws ecr describe-images \
            --region "$AWS_REGION" \
            --repository-name "$service" \
            --image-ids "imageTag=$IMAGE_TAG" >/dev/null 2>&1; then
            log_error "Missing image tag in ECR: $service:$IMAGE_TAG"
            missing=1
        fi
    done

    if [[ "$missing" -ne 0 ]]; then
        log_error "One or more required ECR image tags are missing. Push images before deploy."
        exit 1
    fi

    log_info "✓ All required ECR image tags exist"
}

create_namespace() {
    log_info "Creating namespace: $NAMESPACE"
    kubectl apply -f "$SCRIPT_DIR/base/namespace.yaml" || true
    
    # Wait for namespace
    kubectl get namespace $NAMESPACE || sleep 2
}

setup_ecr_credentials() {
    if [[ "$USE_IRSA_FOR_ECR" == "true" ]]; then
        log_info "Configuring IRSA-based authentication for image access..."

        if [[ -z "$IRSA_ECR_ROLE_ARN" ]]; then
            log_error "USE_IRSA_FOR_ECR=true requires IRSA_ECR_ROLE_ARN to be set"
            exit 1
        fi

        kubectl annotate serviceaccount default \
          -n "$NAMESPACE" \
          eks.amazonaws.com/role-arn="$IRSA_ECR_ROLE_ARN" \
          --overwrite

        log_info "✓ IRSA annotation applied to default service account"
        return
    fi

    log_info "Setting up ECR credentials..."
    
    # Check if ecr-secret already exists
    if kubectl get secret ecr-secret -n $NAMESPACE &> /dev/null; then
        log_warn "ECR secret already exists. Updating..."
        kubectl delete secret ecr-secret -n $NAMESPACE
    fi
    
    # Get ECR token
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ECR_TOKEN=$(aws ecr get-authorization-token --region ${AWS_REGION} \
      --query 'authorizationData[0].authorizationToken' \
      --output text)
    
    # Decode token
    IFS=':' read -r USERNAME PASSWORD <<< "$(echo $ECR_TOKEN | base64 -d)"
    REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
    
    # Create secret
    kubectl create secret docker-registry ecr-secret \
      --docker-server=$REGISTRY \
      --docker-username=$USERNAME \
      --docker-password=$PASSWORD \
      --docker-email=admin@example.com \
      --namespace=$NAMESPACE \
      --dry-run=client \
      -o yaml | kubectl apply -f -
    
    log_info "✓ ECR credentials updated"
}

deploy_microservices() {
    log_info "Deploying microservices..."
    
    # Build and deploy with kustomize
    kubectl apply -k "$SCRIPT_DIR/base/"
    
    log_info "✓ Microservices deployed"
}

wait_for_deployments() {
    log_info "Waiting for deployments to be ready..."
    
    # Get list of deployments
    DEPLOYMENTS=$(kubectl get deployments -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}')
    
    for deployment in $DEPLOYMENTS; do
        log_info "Waiting for $deployment..."
        kubectl rollout status deployment/$deployment -n $NAMESPACE --timeout=5m
    done
    
    log_info "✓ All deployments ready"
}

print_status() {
    log_info "Deployment Status:"
    echo ""
    
    echo "Namespace:"
    kubectl get namespace $NAMESPACE
    echo ""
    
    echo "Deployments:"
    kubectl get deployments -n $NAMESPACE
    echo ""
    
    echo "Services:"
    kubectl get services -n $NAMESPACE
    echo ""
    
    echo "Pods:"
    kubectl get pods -n $NAMESPACE
    echo ""

    FRONTEND_DNS=$(kubectl get svc frontend-external -n $NAMESPACE \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

    if [ -n "$FRONTEND_DNS" ]; then
        echo -e "${GREEN}Access frontend at:${NC} http://$FRONTEND_DNS"
    else
        log_warn "Frontend external LoadBalancer is still provisioning."
    fi
}

main() {
    log_info "Starting microservices deployment to EKS"
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Region: $AWS_REGION"
    log_info "Namespace: $NAMESPACE"
    log_info "Compute mode: $COMPUTE_MODE"
    log_info "Image tag: $IMAGE_TAG"
    log_info "Use IRSA for ECR auth: $USE_IRSA_FOR_ECR"
    echo ""
    
    check_prerequisites
    validate_manifest_schema
    enforce_compute_path
    check_compute_health
    verify_ecr_images
    create_namespace
    setup_ecr_credentials
    deploy_microservices
    wait_for_deployments
    print_status
    
    log_info "Deployment completed successfully!"
}

# Run main function
main

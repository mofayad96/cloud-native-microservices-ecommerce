SHELL := /bin/bash
AWS_REGION ?= eu-central-1
CLUSTER_NAME ?= microservices-cluster

# ─── Help ────────────────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "── Terraform ─────────────────────────────"
	@echo "  tf-init       Initialize Terraform"
	@echo "  tf-plan       Run terraform plan"
	@echo "  tf-apply      Run terraform apply"
	@echo "  tf-destroy    Run terraform destroy"
	@echo "  tf-fmt        Format Terraform files"
	@echo "  tf-validate   Validate Terraform config"
	@echo ""
	@echo "── Go Services ───────────────────────────"
	@echo "  go-build      Build all Go services"
	@echo "  go-test       Test all Go services"
	@echo "  go-vet        Vet all Go services"
	@echo ""
	@echo "── cartservice (.NET) ────────────────────"
	@echo "  dotnet-build  Build cartservice"
	@echo "  dotnet-test   Test cartservice"
	@echo ""
	@echo "── adservice (Java/Gradle) ───────────────"
	@echo "  gradle-build  Build adservice"
	@echo "  gradle-lint   Verify Java formatting"
	@echo ""
	@echo "── Docker ────────────────────────────────"
	@echo "  docker-build  Build all service images"
	@echo ""
	@echo "── Kubernetes ────────────────────────────"
	@echo "  k8s-validate  Validate Kustomize manifests"
	@echo "  k8s-deploy    Deploy to EKS (via deploy.sh)"
	@echo ""
	@echo "── Local Dev ─────────────────────────────"
	@echo "  dev-up        Start all services via docker-compose"
	@echo "  dev-down      Stop all services"
	@echo "  dev-logs      Follow logs"
	@echo ""
	@echo "── Quality ───────────────────────────────"
	@echo "  lint          Run all available linters"
	@echo "  test          Run all tests"
	@echo "  clean         Clean build artifacts"

# ─── Terraform ──────────────────────────────────────────────────────────
TERRAFORM_DIR := terraform

tf-init:
	cd $(TERRAFORM_DIR) && terraform init

tf-plan:
	cd $(TERRAFORM_DIR) && terraform plan

tf-apply:
	cd $(TERRAFORM_DIR) && terraform apply

tf-destroy:
	cd $(TERRAFORM_DIR) && terraform destroy

tf-fmt:
	cd $(TERRAFORM_DIR) && terraform fmt -recursive

tf-validate:
	cd $(TERRAFORM_DIR) && terraform validate

# ─── Go Services ────────────────────────────────────────────────────────
GO_SERVICES := checkoutservice frontend productcatalogservice shippingservice

go-build: $(GO_SERVICES:%=go-build-%)
go-test: $(GO_SERVICES:%=go-test-%)
go-vet: $(GO_SERVICES:%=go-vet-%)

go-build-%:
	cd src/$* && go build -o /dev/null ./...

go-test-%:
	cd src/$* && go test ./...

go-vet-%:
	cd src/$* && go vet ./...

# ─── cartservice (.NET) ─────────────────────────────────────────────────
DOTNET_DIR := src/cartservice

dotnet-restore:
	dotnet restore $(DOTNET_DIR)/cartservice.csproj

dotnet-build: dotnet-restore
	dotnet publish $(DOTNET_DIR)/cartservice.csproj -c release -o /tmp/cartservice-out

dotnet-test:
	dotnet test $(DOTNET_DIR)/tests/cartservice.tests.csproj

# ─── adservice (Java/Gradle) ────────────────────────────────────────────
AD_DIR := src/adservice

gradle-build:
	cd $(AD_DIR) && ./gradlew installDist

gradle-lint:
	cd $(AD_DIR) && ./gradlew verifyGoogleJavaFormat

gradle-format:
	cd $(AD_DIR) && ./gradlew googleJavaFormat

# ─── Docker ─────────────────────────────────────────────────────────────
SERVICES := adservice cartservice checkoutservice currencyservice emailservice frontend paymentservice productcatalogservice recommendationservice shippingservice

docker-build: $(SERVICES:%=docker-build-%)
docker-build-%:
	docker build -t $*:latest src/$*

# ─── Kubernetes ─────────────────────────────────────────────────────────
k8s-validate:
	kubectl kustomize k8s/base/ > /dev/null
	@echo "Manifests valid"

k8s-deploy:
	./k8s/deploy.sh

# ─── Local Dev ──────────────────────────────────────────────────────────
dev-up:
	docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d

dev-down:
	docker compose -f docker-compose.yml -f docker-compose.dev.yml down

dev-logs:
	docker compose -f docker-compose.yml -f docker-compose.dev.yml logs -f

# ─── Quality ────────────────────────────────────────────────────────────
lint: go-vet gradle-lint

test: go-test dotnet-test

clean:
	find . -name '*.pyc' -delete
	find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
	rm -rf $(addprefix src/, $(addsuffix /vendor, $(GO_SERVICES)))
	rm -rf /tmp/cartservice-out

# ─── State migration ───────────────────────────────────────────────────
.PHONY: tf-migrate-state
tf-migrate-state:
	@echo "Step 1: Create S3 bucket + DynamoDB table"
	cd $(TERRAFORM_DIR) && terraform apply -target=aws_s3_bucket.terraform_state -target=aws_dynamodb_table.terraform_lock -auto-approve
	@echo ""
	@echo "Step 2: Uncomment the backend block in terraform/backend.tf"
	@echo "Step 3: Run: terraform init -migrate-state"
	@echo ""
	@echo "See terraform/backend.tf for full instructions."

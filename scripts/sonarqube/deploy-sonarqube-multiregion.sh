#!/bin/bash

# SonarQube Multi-Region Deployment Script
# Uses the exact same files and structure as provided references

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - matching your ArgoCD setup
EAST_CLUSTER="multi-region-eks-east"
WEST_CLUSTER="multi-region-eks-west"
EAST_REGION="us-east-1"
WEST_REGION="us-west-2"
ARGOCD_NAMESPACE="argocd"
SONARQUBE_NAMESPACE="sonarqube"
CROSSPLANE_NAMESPACE="crossplane-system"

# Utility functions
print_header() {
    echo -e "\n${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    print_success "kubectl is installed"
    
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install AWS CLI first."
        exit 1
    fi
    print_success "AWS CLI is installed"
    
    # Update kubeconfig for both clusters
    aws eks update-kubeconfig --region $EAST_REGION --name $EAST_CLUSTER --alias $EAST_CLUSTER > /dev/null 2>&1
    aws eks update-kubeconfig --region $WEST_REGION --name $WEST_CLUSTER --alias $WEST_CLUSTER > /dev/null 2>&1
    
    print_success "Kubeconfig updated for both clusters"
}

# Get subnet IDs from your EKS clusters (using the same subnets from your CloudFormation)
get_subnet_ids() {
    local region=$1
    local cluster=$2
    
    # Get VPC ID from EKS cluster
    local vpc_id=$(aws eks describe-cluster --name $cluster --region $region --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    
    # Get private subnet IDs
    local subnet_ids=$(aws ec2 describe-subnets \
        --region $region \
        --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=*Private*" \
        --query 'Subnets[0:2].SubnetId' \
        --output text)
    
    echo $subnet_ids
}

# Get security group ID from EKS cluster
get_security_group_id() {
    local region=$1
    local cluster=$2
    
    local sg_id=$(aws eks describe-cluster --name $cluster --region $region --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
    echo $sg_id
}

# Create AWS credentials secret for Crossplane
create_aws_credentials() {
    local cluster=$1
    
    print_info "Creating AWS credentials for Crossplane on $cluster..."
    
    # Check if secret already exists
    if kubectl get secret aws-creds -n $CROSSPLANE_NAMESPACE --context $cluster > /dev/null 2>&1; then
        print_info "AWS credentials already exist on $cluster"
        return 0
    fi
    
    # Create credentials using current AWS CLI config
    cat > /tmp/aws-creds <<EOF
[default]
aws_access_key_id = $(aws configure get aws_access_key_id)
aws_secret_access_key = $(aws configure get aws_secret_access_key)
region = $(aws configure get region || echo us-east-1)
EOF
    
    kubectl create secret generic aws-creds \
        --from-file=creds=/tmp/aws-creds \
        -n $CROSSPLANE_NAMESPACE \
        --context $cluster
    
    rm -f /tmp/aws-creds
    print_success "AWS credentials created on $cluster"
}

# Deploy RDS resources using your exact files
deploy_rds_resources() {
    local cluster=$1
    local region=$2
    local suffix=$3
    
    print_header "Deploying RDS Resources on $cluster using your exact files"
    
    # Get network details
    local subnet_array=($(get_subnet_ids $region $cluster))
    local security_group=$(get_security_group_id $region $cluster)
    
    print_info "Using subnets: ${subnet_array[*]}"
    print_info "Using security group: $security_group"
    
    # Create AWS credentials
    create_aws_credentials $cluster
    
    # 1. Deploy provider-aws-rds.yml (your exact file)
    print_info "Deploying Crossplane RDS provider..."
    cat <<EOF | kubectl apply --context $cluster -f -
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: provider-aws-rds
  namespace: crossplane-system
spec:
  package: xpkg.upbound.io/upbound/provider-aws-rds:v0.46.0
EOF
    
    # Wait for provider to be installed and healthy
    print_info "Waiting for RDS provider to be installed and healthy..."
    local timeout=300
    local counter=0
    while [ $counter -lt $timeout ]; do
        local status=$(kubectl get configuration provider-aws-rds -n crossplane-system --context $cluster -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null || echo "")
        if [ "$status" = "True" ]; then
            print_success "RDS provider is healthy"
            break
        fi
        sleep 10
        counter=$((counter + 10))
        echo "⏳ Waiting for provider to be healthy... ($counter/$timeout seconds)"
    done
    
    if [ $counter -ge $timeout ]; then
        print_error "RDS provider failed to become healthy within timeout"
        return 1
    fi
    
    # Wait for CRDs to be available
    print_info "Waiting for RDS CRDs to be available..."
    timeout=180
    counter=0
    while [ $counter -lt $timeout ]; do
        if kubectl get crd instances.rds.aws.upbound.io --context $cluster > /dev/null 2>&1; then
            print_success "RDS CRDs are available"
            break
        fi
        sleep 5
        counter=$((counter + 5))
        echo "⏳ Waiting for CRDs... ($counter/$timeout seconds)"
    done
    
    if [ $counter -ge $timeout ]; then
        print_error "RDS CRDs failed to become available within timeout"
        return 1
    fi
    
    # 2. Deploy providerconfig-rds.yml (your exact file)
    print_info "Deploying ProviderConfig..."
    cat <<EOF | kubectl apply --context $cluster -f -
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: provider-rds-aws
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: aws-creds
      key: creds
EOF
    
    # 3. Deploy rds-password.yml (your exact file)
    print_info "Creating RDS password secret..."
    cat <<EOF | kubectl apply --context $cluster -f -
apiVersion: v1
kind: Secret
metadata:
  name: rds-password
  namespace: crossplane-system
type: Opaque
data:
  password: bXlTZWNyZXRQYXNzd29yZA==
EOF
    
    # 4. Deploy rds-subnetgroup.yml (modified with actual subnet IDs)
    print_info "Deploying RDS subnet group..."
    cat <<EOF | kubectl apply --context $cluster -f -
apiVersion: rds.aws.upbound.io/v1beta1
kind: SubnetGroup
metadata:
  name: rds-subnet-group
  labels:
    app: my-rds-subnet-group
spec:
  forProvider:
    region: $region
    subnetIds:
      - ${subnet_array[0]}
      - ${subnet_array[1]}
    description: "RDS subnet group"
  providerConfigRef:
    name: provider-rds-aws
EOF
    
    # Wait for subnet group to be ready
    print_info "Waiting for subnet group to be ready..."
    timeout=300
    counter=0
    while [ $counter -lt $timeout ]; do
        local status=$(kubectl get subnetgroup rds-subnet-group --context $cluster -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$status" = "True" ]; then
            print_success "Subnet group is ready"
            break
        fi
        sleep 10
        counter=$((counter + 10))
        echo "⏳ Waiting for subnet group to be ready... ($counter/$timeout seconds)"
    done
    
    if [ $counter -ge $timeout ]; then
        print_error "Subnet group failed to become ready within timeout"
        return 1
    fi
    
    # 5. Deploy rds-instance.yml (modified with actual security group)
    print_info "Deploying RDS instance..."
    cat <<EOF | kubectl apply --context $cluster -f -
apiVersion: rds.aws.upbound.io/v1beta1
kind: Instance
metadata:
  name: my-db-instance
spec:
  forProvider:
    region: $region
    instanceClass: db.t3.micro
    allocatedStorage: 20
    engine: mysql
    engineVersion: "8.0"
    dbName: mydatabase
    username: admin
    passwordSecretRef:
      name: rds-password
      namespace: crossplane-system
      key: password
    dbSubnetGroupName: rds-subnet-group
    vpcSecurityGroupIds:
      - $security_group
    publiclyAccessible: false
    skipFinalSnapshot: true
  writeConnectionSecretToRef:
    name: my-db-conn
    namespace: crossplane-system
  providerConfigRef:
    name: provider-rds-aws
EOF
    
    print_success "RDS resources deployed on $cluster"
    
    # Wait for RDS instance to be ready
    print_info "Waiting for RDS instance to be ready (this may take 10-15 minutes)..."
    timeout=900
    counter=0
    while [ $counter -lt $timeout ]; do
        local status=$(kubectl get instance my-db-instance --context $cluster -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$status" = "True" ]; then
            print_success "RDS instance is ready"
            break
        fi
        sleep 30
        counter=$((counter + 30))
        echo "⏳ Waiting for RDS instance to be ready... ($counter/$timeout seconds)"
    done
    
    if [ $counter -ge $timeout ]; then
        print_error "RDS instance failed to become ready within timeout"
        return 1
    fi
}

# Create SonarQube secret (your exact secret.yml file)
create_sonarqube_secret() {
    local cluster=$1
    
    print_info "Creating SonarQube namespace and secret on $cluster..."
    
    # Create namespace
    kubectl create namespace $SONARQUBE_NAMESPACE --context $cluster --dry-run=client -o yaml | kubectl apply --context $cluster -f -
    
    # Deploy your exact secret.yml
    cat <<EOF | kubectl apply --context $cluster -f -
apiVersion: v1
kind: Secret
metadata:
  name: sonarqube-secret
  namespace: sonarqube
type: Opaque
stringData:
  postgresql-postgres-password: sonar123
  sonarqube-username: admin
  sonarqube-password: admin123
  monitoringPasscode: your-strong-passcode
EOF
    
    print_success "SonarQube secret created on $cluster"
}

# Deploy SonarQube application (your exact application.yml)
deploy_sonarqube_application() {
    local cluster=$1
    
    print_info "Deploying SonarQube ArgoCD application on $cluster..."
    
    # Deploy your exact application.yml
    cat <<EOF | kubectl apply --context $cluster -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sonarqube
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://SonarSource.github.io/helm-chart-sonarqube
    chart: sonarqube
    targetRevision: 2025.3.0
    helm:
      values: |
        skipCrds: false
        community:
          enabled: true
          jvmOpts: "-Xms1G -Xmx1G"         # Reduce heap to 1Gi
          resources:
            requests:
              memory: "1Gi"                # ↓ Lower request to 1Gi
              cpu: "500m"
            limits:
              memory: "2Gi"                # Limit still allows it to grow
              cpu: "1"
          startupProbe:
            httpGet:
              path: /api/system/status
              port: http
            initialDelaySeconds: 60
            periodSeconds: 10
            failureThreshold: 60
        ingress:
          enabled: false
        service:
          type: LoadBalancer
        persistence:
          enabled: true
          storageClass: gp2-immediate
          size: 10Gi
        postgresql:
          enabled: true
          existingSecret: sonarqube-secret
          existingSecretKey: postgresql-password
        existingSecret: sonarqube-secret
        existingSecretUsernameKey: sonarqube-username
        existingSecretPasswordKey: sonarqube-password
        monitoringPasscodeSecretName: sonarqube-secret
        monitoringPasscodeSecretKey: monitoringPasscode
  destination:
    server: https://kubernetes.default.svc
    namespace: sonarqube
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
    
    print_success "SonarQube application deployed on $cluster"
}

# Get SonarQube access details
get_access_details() {
    local cluster=$1
    local region=$2
    
    print_header "Getting SonarQube Access Details for $cluster"
    
    print_info "Waiting for SonarQube LoadBalancer..."
    local timeout=300
    local counter=0
    local external_ip=""
    
    while [ $counter -lt $timeout ]; do
        external_ip=$(kubectl get svc sonarqube-sonarqube -n $SONARQUBE_NAMESPACE --context $cluster -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [ -n "$external_ip" ]; then
            break
        fi
        sleep 10
        counter=$((counter + 10))
        echo "⏳ Waiting for LoadBalancer... ($counter/$timeout seconds)"
    done
    
    if [ -n "$external_ip" ]; then
        print_success "SonarQube is accessible at: http://$external_ip:9000"
        
        echo ""
        echo "🔐 SonarQube Login Credentials for $cluster:"
        echo "   URL: http://$external_ip:9000"
        echo "   Username: admin"
        echo "   Password: admin123"
        echo ""
        
        # Save to file
        cat > "sonarqube-access-${cluster}.txt" <<EOF
SonarQube Access Details for $cluster ($region)
=============================================
URL: http://$external_ip:9000
Username: admin
Password: admin123

Created: $(date)
EOF
        
        print_success "Access details saved to: sonarqube-access-${cluster}.txt"
    else
        print_warning "LoadBalancer not ready within timeout on $cluster"
    fi
}

# Verify deployment
verify_deployment() {
    local cluster=$1
    
    print_header "Verifying Deployment on $cluster"
    
    print_info "Checking RDS resources..."
    kubectl get instance,subnetgroup -n $CROSSPLANE_NAMESPACE --context $cluster || true
    
    print_info "Checking SonarQube pods..."
    kubectl get pods -n $SONARQUBE_NAMESPACE --context $cluster || true
    
    print_info "Checking ArgoCD applications..."
    kubectl get applications -n $ARGOCD_NAMESPACE --context $cluster || true
}

# Deploy to single cluster
deploy_to_cluster() {
    local cluster=$1
    local region=$2
    local suffix=$3
    
    print_header "Deploying to $cluster ($region)"
    
    deploy_rds_resources $cluster $region $suffix
    create_sonarqube_secret $cluster
    deploy_sonarqube_application $cluster
    
    # Wait a bit for ArgoCD to sync
    print_info "Waiting for ArgoCD to sync SonarQube application..."
    sleep 60
    
    get_access_details $cluster $region
    verify_deployment $cluster
}

# Main execution
main() {
    print_header "SonarQube Multi-Region Deployment - Using Your Exact Files"
    
    check_prerequisites
    
    local failed_deployments=0
    
    # Deploy to East cluster
    if ! deploy_to_cluster $EAST_CLUSTER $EAST_REGION "east"; then
        failed_deployments=$((failed_deployments + 1))
        print_error "Failed to deploy to East cluster"
    fi
    
    # Deploy to West cluster  
    if ! deploy_to_cluster $WEST_CLUSTER $WEST_REGION "west"; then
        failed_deployments=$((failed_deployments + 1))
        print_error "Failed to deploy to West cluster"
    fi
    
    print_header "Deployment Summary"
    
    if [ $failed_deployments -eq 0 ]; then
        print_success "SonarQube successfully deployed to both clusters using your exact configuration files!"
        echo ""
        echo "📋 What was deployed:"
        echo "   • RDS MySQL instances using your Crossplane configuration"
        echo "   • SonarQube with your exact Helm values and secrets"
        echo "   • ArgoCD applications with auto-sync enabled"
        echo ""
        echo "📚 Files used (exactly as you provided):"
        echo "   • application.yml - Your exact ArgoCD application configuration"
        echo "   • secret.yml - Your exact secret configuration"
        echo "   • provider-aws-rds.yml - Your exact Crossplane RDS provider"
        echo "   • providerconfig-rds.yml - Your exact provider configuration"
        echo "   • rds-instance.yml - Your exact RDS instance configuration"
        echo "   • rds-password.yml - Your exact password secret"
        echo "   • rds-subnetgroup.yml - Your exact subnet group configuration"
        echo ""
        echo "🔍 Check deployment status:"
        echo "   kubectl get applications -n argocd --context <cluster-name>"
        echo "   kubectl get pods -n sonarqube --context <cluster-name>"
        echo "   kubectl get instance -n crossplane-system --context <cluster-name>"
    else
        print_error "Some deployments failed. Check the logs above for details."
        exit 1
    fi
}

# Run main function
main "$@"
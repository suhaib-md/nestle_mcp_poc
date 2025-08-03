#!/bin/bash

# SonarQube Deployment Script
# Deploys SonarQube to EKS clusters using Helm
# Based on the successful Jenkins deployment pattern

set -e

# Configuration
EAST_CLUSTER="multi-region-eks-east"
WEST_CLUSTER="multi-region-eks-west"
EAST_REGION="us-east-1"
WEST_REGION="us-west-2"
SONARQUBE_NAMESPACE="sonarqube-app"
SONARQUBE_RELEASE_NAME="sonarqube-app"
SONARQUBE_ADMIN_USER="admin"
SONARQUBE_ADMIN_PASSWORD="SonarQube123!"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }

# Parse arguments
USE_PERSISTENCE=false
TARGET_CLUSTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --with-persistence)
            USE_PERSISTENCE=true
            shift
            ;;
        east|$EAST_CLUSTER)
            TARGET_CLUSTER="east"
            shift
            ;;
        west|$WEST_CLUSTER)
            TARGET_CLUSTER="west"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [east|west] [--with-persistence]"
            echo "  east/west: Deploy to specific cluster only"
            echo "  --with-persistence: Enable persistent storage (requires working EBS CSI)"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Setup Helm repository
setup_helm() {
    print_info "Setting up SonarQube Helm repository..."
    helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    print_success "SonarQube Helm repository updated"
}

# Deploy SonarQube to a cluster
deploy_sonarqube() {
    local cluster_name=$1
    local region=$2
    
    print_info "Deploying SonarQube to $cluster_name..."
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name >/dev/null 2>&1
    
    # Create namespace
    kubectl create namespace $SONARQUBE_NAMESPACE --dry-run=client -o yaml | kubectl apply -f - --context=$cluster_name
    
    # Create storage class if using persistence
    if [ "$USE_PERSISTENCE" = "true" ]; then
        print_info "Creating storage class for persistence..."
        cat <<EOF | kubectl apply --context=$cluster_name -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-csi-gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
    fi
    
    # Create Helm values file
    local values_file="/tmp/sonarqube-values-${cluster_name}.yaml"
    
    cat > "$values_file" <<EOF
# SonarQube Community Edition configuration
community:
  enabled: true

# SonarQube configuration
sonarqube:
  adminPassword: "$SONARQUBE_ADMIN_PASSWORD"

# Monitoring configuration (required)
monitoringPasscode: "SonarMonitoring123!"

# Service configuration
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"

# Resource configuration
resources:
  requests:
    cpu: "500m"
    memory: "2Gi"
  limits:
    cpu: "2000m"
    memory: "4Gi"

# Tolerations for EKS Auto Mode
tolerations:
  - key: "CriticalAddonsOnly"
    operator: "Exists"
    effect: "NoSchedule"
  - key: "karpenter.sh/disrupted"
    operator: "Exists"
    effect: "NoSchedule"

# Persistence configuration
persistence:
  enabled: $USE_PERSISTENCE
$([ "$USE_PERSISTENCE" = "true" ] && echo "  size: 20Gi" && echo "  storageClass: \"ebs-csi-gp3\"")

# PostgreSQL configuration
postgresql:
  enabled: true
  auth:
    postgresPassword: "SonarPostgres123!"
    database: "sonarqube"
  primary:
    persistence:
      enabled: $USE_PERSISTENCE
$([ "$USE_PERSISTENCE" = "true" ] && echo "      size: 20Gi" && echo "      storageClass: \"ebs-csi-gp3\"")
    resources:
      requests:
        cpu: "250m"
        memory: "512Mi"
      limits:
        cpu: "1000m"
        memory: "1Gi"

# Service account
serviceAccount:
  create: true
  name: sonarqube

# Init containers for system requirements
initContainers:
  securityContext:
    privileged: true
    allowPrivilegeEscalation: true
  image: busybox:1.35
  command:
    - sh
    - -c
    - |
      sysctl -w vm.max_map_count=524288
      sysctl -w fs.file-max=131072

# JVM options for SonarQube
sonarProperties:
  sonar.forceAuthentication: "true"
EOF
    
    # Remove any existing release
    helm uninstall $SONARQUBE_RELEASE_NAME -n $SONARQUBE_NAMESPACE --kube-context $cluster_name >/dev/null 2>&1 || true
    
    # Install SonarQube
    print_info "Installing SonarQube via Helm..."
    helm install $SONARQUBE_RELEASE_NAME sonarqube/sonarqube \
        --namespace $SONARQUBE_NAMESPACE \
        --kube-context $cluster_name \
        --values "$values_file" \
        --wait \
        --timeout 10m
    
    # Clean up values file
    rm -f "$values_file"
    
    # Get LoadBalancer URL
    print_info "Getting LoadBalancer URL..."
    local timeout=180
    local counter=0
    local external_ip=""
    
    while [ $counter -lt $timeout ]; do
        external_ip=$(kubectl get svc $SONARQUBE_RELEASE_NAME-sonarqube -n $SONARQUBE_NAMESPACE --context=$cluster_name -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [ -n "$external_ip" ]; then
            break
        fi
        sleep 10
        counter=$((counter + 10))
        print_info "Waiting for LoadBalancer... (${counter}s/${timeout}s)"
    done
    
    if [ -n "$external_ip" ]; then
        local url="http://$external_ip:9000"
        print_success "SonarQube deployed successfully on $cluster_name!"
        echo "🌐 URL: $url"
        echo "👤 Username: $SONARQUBE_ADMIN_USER"
        echo "🔑 Password: $SONARQUBE_ADMIN_PASSWORD"
        
        # Save credentials
        cat > "sonarqube-credentials-${cluster_name}.txt" <<EOF
SonarQube Deployment - $cluster_name
Namespace: $SONARQUBE_NAMESPACE
URL: $url
Username: $SONARQUBE_ADMIN_USER
Password: $SONARQUBE_ADMIN_PASSWORD
PostgreSQL Password: SonarPostgres123!
Monitoring Passcode: SonarMonitoring123!
Persistence: $USE_PERSISTENCE

Management Commands:
- Status: helm status $SONARQUBE_RELEASE_NAME -n $SONARQUBE_NAMESPACE --kube-context $cluster_name
- Upgrade: helm upgrade $SONARQUBE_RELEASE_NAME sonarqube/sonarqube -n $SONARQUBE_NAMESPACE --kube-context $cluster_name --values <values-file>
- Uninstall: helm uninstall $SONARQUBE_RELEASE_NAME -n $SONARQUBE_NAMESPACE --kube-context $cluster_name
EOF
        print_success "Credentials saved to sonarqube-credentials-${cluster_name}.txt"
        return 0
    else
        print_error "LoadBalancer not ready within timeout"
        return 1
    fi
}

# Main execution
main() {
    echo "🚀 SonarQube Deployment Script"
    echo "Persistence: $USE_PERSISTENCE"
    echo "Target: ${TARGET_CLUSTER:-both clusters}"
    echo ""
    
    setup_helm
    
    local failed_deployments=0
    local successful_deployments=()
    
    if [ "$TARGET_CLUSTER" = "east" ]; then
        if deploy_sonarqube $EAST_CLUSTER $EAST_REGION; then
            successful_deployments+=("$EAST_CLUSTER")
        else
            failed_deployments=$((failed_deployments + 1))
        fi
    elif [ "$TARGET_CLUSTER" = "west" ]; then
        if deploy_sonarqube $WEST_CLUSTER $WEST_REGION; then
            successful_deployments+=("$WEST_CLUSTER")
        else
            failed_deployments=$((failed_deployments + 1))
        fi
    else
        # Deploy to both clusters
        if deploy_sonarqube $EAST_CLUSTER $EAST_REGION; then
            successful_deployments+=("$EAST_CLUSTER")
        else
            failed_deployments=$((failed_deployments + 1))
        fi
        
        echo ""
        
        if deploy_sonarqube $WEST_CLUSTER $WEST_REGION; then
            successful_deployments+=("$WEST_CLUSTER")
        else
            failed_deployments=$((failed_deployments + 1))
        fi
    fi
    
    echo ""
    echo "🎯 Deployment Summary:"
    if [ $failed_deployments -eq 0 ]; then
        print_success "SonarQube deployed successfully on all target clusters!"
        echo "Successful deployments: ${successful_deployments[*]}"
    else
        print_warning "Deployment completed with $failed_deployments failure(s)"
        if [ ${#successful_deployments[@]} -gt 0 ]; then
            echo "Successful: ${successful_deployments[*]}"
        fi
    fi
    
    echo ""
    echo "📋 Next steps:"
    echo "1. Access SonarQube using the URLs above"
    echo "2. Change the default admin password"
    echo "3. Run ./scripts/sonarqube/create-sonarqube-argocd-apps.sh to add ArgoCD management"
    echo "4. Configure project analysis and quality gates"
}

main "$@"
#!/bin/bash

# ArgoCD Installation and Configuration Script
# Installs ArgoCD on both EKS clusters using Helm

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
EAST_CLUSTER="multi-region-eks-east"
WEST_CLUSTER="multi-region-eks-west"
EAST_REGION="us-east-1"
WEST_REGION="us-west-2"
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="7.7.7" # Latest stable Helm chart version

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
    
    if ! command -v helm &> /dev/null; then
        print_error "Helm is not installed. Please install Helm first."
        exit 1
    fi
    print_success "Helm is installed: $(helm version)"
    
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    print_success "kubectl is installed: $(kubectl version --client)"
    
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install AWS CLI first."
        exit 1
    fi
    print_success "AWS CLI is installed: $(aws --version)"
}

# Add ArgoCD Helm repository
add_helm_repo() {
    print_header "Adding ArgoCD Helm Repository"
    
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    
    print_success "ArgoCD Helm repository added and updated"
}

# Clean up existing ArgoCD CRDs and cluster-scoped resources
cleanup_existing_resources() {
    local cluster_name=$1
    print_header "Cleaning up existing ArgoCD resources on $cluster_name"
    
    # List of ArgoCD CRDs
    local crds=(
        "applications.argoproj.io"
        "appprojects.argoproj.io"
        "applicationsets.argoproj.io"
    )
    
    # Clean up CRDs
    for crd in "${crds[@]}"; do
        if kubectl get crd $crd --context $cluster_name &> /dev/null; then
            print_info "Found existing CRD: $crd. Checking ownership..."
            local managed_by=$(kubectl get crd $crd --context $cluster_name -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
            local release_name=$(kubectl get crd $crd --context $cluster_name -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
            
            if [[ "$managed_by" != "Helm" || "$release_name" != "argocd" ]]; then
                print_warning "CRD $crd has conflicting ownership. Deleting to allow fresh installation..."
                kubectl delete crd $crd --context $cluster_name --ignore-not-found=true
                print_success "CRD $crd deleted successfully"
            else
                print_info "CRD $crd is already managed by Helm with correct ownership. Skipping cleanup."
            fi
        else
            print_info "CRD $crd does not exist. No cleanup needed."
        fi
    done
    
    # List of ArgoCD cluster-scoped resources (ClusterRole and ClusterRoleBinding)
    local cluster_roles=(
        "argocd-application-controller"
        "argocd-server"
    )
    local cluster_role_bindings=(
        "argocd-application-controller"
        "argocd-server"
    )
    
    # Clean up ClusterRoles
    for cr in "${cluster_roles[@]}"; do
        if kubectl get clusterrole $cr --context $cluster_name &> /dev/null; then
            print_info "Found existing ClusterRole: $cr. Checking ownership..."
            local managed_by=$(kubectl get clusterrole $cr --context $cluster_name -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
            local release_name=$(kubectl get clusterrole $cr --context $cluster_name -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
            
            if [[ "$managed_by" != "Helm" || "$release_name" != "argocd" ]]; then
                print_warning "ClusterRole $cr has conflicting ownership. Deleting to allow fresh installation..."
                kubectl delete clusterrole $cr --context $cluster_name --ignore-not-found=true
                print_success "ClusterRole $cr deleted successfully"
            else
                print_info "ClusterRole $cr is already managed by Helm with correct ownership. Skipping cleanup."
            fi
        else
            print_info "ClusterRole $cr does not exist. No cleanup needed."
        fi
    done
    
    # Clean up ClusterRoleBindings
    for crb in "${cluster_role_bindings[@]}"; do
        if kubectl get clusterrolebinding $crb --context $cluster_name &> /dev/null; then
            print_info "Found existing ClusterRoleBinding: $crb. Checking ownership..."
            local managed_by=$(kubectl get clusterrolebinding $crb --context $cluster_name -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
            local release_name=$(kubectl get clusterrolebinding $crb --context $cluster_name -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
            
            if [[ "$managed_by" != "Helm" || "$release_name" != "argocd" ]]; then
                print_warning "ClusterRoleBinding $crb has conflicting ownership. Deleting to allow fresh installation..."
                kubectl delete clusterrolebinding $crb --context $cluster_name --ignore-not-found=true
                print_success "ClusterRoleBinding $crb deleted successfully"
            else
                print_info "ClusterRoleBinding $crb is already managed by Helm with correct ownership. Skipping cleanup."
            fi
        else
            print_info "ClusterRoleBinding $crb does not exist. No cleanup needed."
        fi
    done
}

# Install ArgoCD on a cluster
install_argocd() {
    local cluster_name=$1
    local region=$2
    
    print_header "Installing ArgoCD on $cluster_name ($region)"
    
    # Update kubeconfig
    print_info "Updating kubeconfig for $cluster_name..."
    if ! aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name > /dev/null 2>&1; then
        print_error "Failed to update kubeconfig for $cluster_name"
        return 1
    fi
    
    # Clean up existing resources
    cleanup_existing_resources $cluster_name
    
    # Create namespace
    print_info "Creating ArgoCD namespace..."
    kubectl create namespace $ARGOCD_NAMESPACE --context $cluster_name --dry-run=client -o yaml | kubectl apply --context $cluster_name -f -
    
    # Clean up old release just in case
    print_info "Uninstalling any previous Helm release..."
    helm uninstall argocd --namespace $ARGOCD_NAMESPACE --kube-context $cluster_name || true

    # Install ArgoCD using Helm
    print_info "Installing ArgoCD using Helm (version: $ARGOCD_VERSION)..."
    if ! helm upgrade --install argocd argo/argo-cd \
        --version $ARGOCD_VERSION \
        --namespace $ARGOCD_NAMESPACE \
        --kube-context $cluster_name \
        --timeout 10m \
        --set installCRDs=true \
        --set configs.params."server\.insecure"=true \
        --set server.service.type=LoadBalancer \
        --set server.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb" \
        --set server.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"="internet-facing" \
        --set server.extraArgs="{--insecure}" \
        --set repoServer.resources.requests.cpu="100m" \
        --set repoServer.resources.requests.memory="128Mi" \
        --set repoServer.resources.limits.cpu="500m" \
        --set repoServer.resources.limits.memory="512Mi" \
        --set server.resources.requests.cpu="100m" \
        --set server.resources.requests.memory="128Mi" \
        --set server.resources.limits.cpu="500m" \
        --set server.resources.limits.memory="512Mi" \
        --set controller.resources.requests.cpu="250m" \
        --set controller.resources.requests.memory="256Mi" \
        --set controller.resources.limits.cpu="1000m" \
        --set controller.resources.limits.memory="1Gi" \
        ; then
        print_error "Failed to install ArgoCD on $cluster_name"
        return 1
    fi

    
    print_success "ArgoCD installed successfully on $cluster_name"
    
    # Wait for ArgoCD server to be ready
    print_info "Waiting for ArgoCD server to be ready..."
    if ! kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n $ARGOCD_NAMESPACE --context $cluster_name; then
        print_error "ArgoCD server failed to become ready on $cluster_name"
        return 1
    fi
    
    # Wait for LoadBalancer to get external IP
    print_info "Waiting for LoadBalancer to be provisioned..."
    local timeout=300
    local counter=0
    local external_ip=""
    
    while [ $counter -lt $timeout ]; do
        external_ip=$(kubectl get svc argocd-server -n $ARGOCD_NAMESPACE --context $cluster_name -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [ -n "$external_ip" ]; then
            break
        fi
        sleep 10
        counter=$((counter + 10))
        echo "⏳ Waiting for LoadBalancer... ($counter/$timeout seconds)"
    done
    
    if [ -n "$external_ip" ]; then
        print_success "ArgoCD server is accessible at: http://$external_ip"
        
        # Get initial admin password
        print_info "Retrieving ArgoCD admin password..."
        local admin_password=$(kubectl get secret argocd-initial-admin-secret -n $ARGOCD_NAMESPACE --context $cluster_name -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "")
        
        if [ -z "$admin_password" ]; then
            print_error "Failed to retrieve ArgoCD admin password on $cluster_name"
            return 1
        fi
        
        echo ""
        echo "🔐 ArgoCD Login Credentials for $cluster_name:"
        echo "   URL: http://$external_ip"
        echo "   Username: admin"
        echo "   Password: $admin_password"
        echo ""
        
        # Store credentials in a file for reference
        cat > "argocd-credentials-${cluster_name}.txt" <<EOF
ArgoCD Credentials for $cluster_name ($region)
============================================
URL: http://$external_ip
Username: admin
Password: $admin_password

Access Date: $(date)
EOF
        
        print_success "Credentials saved to: argocd-credentials-${cluster_name}.txt"
    else
        print_error "LoadBalancer not provisioned within timeout period on $cluster_name"
        return 1
    fi
}

# Verify ArgoCD installation
verify_installation() {
    local cluster_name=$1
    local region=$2
    
    print_header "Verifying ArgoCD Installation on $cluster_name"
    
    print_info "Checking ArgoCD pods status..."
    kubectl get pods -n $ARGOCD_NAMESPACE --context $cluster_name
    
    print_info "Checking ArgoCD services..."
    kubectl get svc -n $ARGOCD_NAMESPACE --context $cluster_name
    
    local not_ready=$(kubectl get pods -n $ARGOCD_NAMESPACE --context $cluster_name --no-headers | grep -v "Running\|Completed" | wc -l)
    if [ "$not_ready" -eq 0 ]; then
        print_success "All ArgoCD pods are running on $cluster_name"
    else
        print_warning "$not_ready pod(s) are not ready on $cluster_name"
    fi
}

# Install ArgoCD CLI (optional but recommended)
install_argocd_cli() {
    print_header "Installing ArgoCD CLI (Optional)"
    
    if command -v argocd &> /dev/null; then
        print_success "ArgoCD CLI is already installed: $(argocd version --client --short 2>/dev/null || echo 'version unknown')"
        return 0
    fi
    
    print_info "Installing ArgoCD CLI..."
    
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="arm" ;;
        *) print_error "Unsupported architecture: $arch"; return 1 ;;
    esac
    
    local version="v2.13.1"
    local url="https://github.com/argoproj/argo-cd/releases/download/${version}/argocd-${os}-${arch}"
    
    print_info "Downloading ArgoCD CLI from: $url"
    if ! curl -sSL -o argocd "$url"; then
        print_error "Failed to download ArgoCD CLI"
        return 1
    fi
    chmod +x argocd
    if ! sudo mv argocd /usr/local/bin/; then
        print_error "Failed to move ArgoCD CLI to /usr/local/bin"
        return 1
    fi
    
    print_success "ArgoCD CLI installed successfully: $(argocd version --client --short)"
}

# Main execution
main() {
    print_header "ArgoCD Installation for Multi-Region EKS"
    
    check_prerequisites
    add_helm_repo
    install_argocd_cli
    
    local failed_installations=0
    
    print_info "Starting installation on East cluster..."
    if ! install_argocd $EAST_CLUSTER $EAST_REGION; then
        failed_installations=$((failed_installations + 1))
    else
        verify_installation $EAST_CLUSTER $EAST_REGION
    fi
    
    print_info "Starting installation on West cluster..."
    if ! install_argocd $WEST_CLUSTER $WEST_REGION; then
        failed_installations=$((failed_installations + 1))
    else
        verify_installation $WEST_CLUSTER $WEST_REGION
    fi
    
    print_header "Installation Summary"
    
    if [ $failed_installations -eq 0 ]; then
        print_success "ArgoCD successfully installed on both clusters!"
        echo ""
        echo "📋 Summary:"
        echo "   • ArgoCD installed on $EAST_CLUSTER (us-east-1)"
        echo "   • ArgoCD installed on $WEST_CLUSTER (us-west-2)"
        echo "   • ArgoCD CLI installed locally"
        echo "   • Credentials saved to argocd-credentials-*.txt files"
        echo ""
        echo "🚀 Next Steps:"
        echo "   • Access ArgoCD UI using the URLs and credentials above"
        echo "   • Configure Git repositories for your applications"
        echo "   • Create ArgoCD applications for Jenkins, SonarQube, and Kyverno"
        echo ""
        echo "📚 Useful Commands:"
        echo "   • Check ArgoCD status: kubectl get pods -n argocd --context <cluster-name>"
        echo "   • Port forward (alternative access): kubectl port-forward svc/argocd-server -n argocd 8080:443 --context <cluster-name>"
        echo "   • ArgoCD CLI login: argocd login <argocd-server-url>"
        echo ""
        print_info "Credentials are saved in argocd-credentials-*.txt files for future reference"
    else
        print_error "Failed to install ArgoCD on $failed_installations cluster(s)"
        exit 1
    fi
}

# Run main function
main "$@"
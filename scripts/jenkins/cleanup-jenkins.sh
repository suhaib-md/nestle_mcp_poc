#!/bin/bash

# Jenkins Cleanup Script
# Removes all Jenkins resources created by deploy-jenkins.sh and create-jenkins-argocd-apps.sh

set -e

# Configuration (matching the deployment scripts)
EAST_CLUSTER="multi-region-eks-east"
WEST_CLUSTER="multi-region-eks-west"
EAST_REGION="us-east-1"
WEST_REGION="us-west-2"
JENKINS_NAMESPACE="jenkins-app"
JENKINS_RELEASE_NAME="jenkins-app"
ARGOCD_APP_NAME="jenkins-lts"
ARGOCD_NAMESPACE="argocd"

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
TARGET_CLUSTER=""
FORCE_DELETE=false
KEEP_NAMESPACE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        east|$EAST_CLUSTER)
            TARGET_CLUSTER="east"
            shift
            ;;
        west|$WEST_CLUSTER)
            TARGET_CLUSTER="west"
            shift
            ;;
        --force)
            FORCE_DELETE=true
            shift
            ;;
        --keep-namespace)
            KEEP_NAMESPACE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [east|west] [--force] [--keep-namespace]"
            echo "  east/west: Clean specific cluster only"
            echo "  --force: Skip confirmation prompts"
            echo "  --keep-namespace: Don't delete the Jenkins namespace"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Confirmation prompt
confirm_cleanup() {
    if [ "$FORCE_DELETE" = "true" ]; then
        return 0
    fi
    
    echo "⚠️  This will remove ALL Jenkins resources including:"
    echo "   - Helm releases"
    echo "   - ArgoCD applications"
    echo "   - Kubernetes namespaces (unless --keep-namespace is used)"
    echo "   - Storage classes"
    echo "   - Load balancers and associated AWS resources"
    echo "   - Persistent volumes (if any)"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    case $confirm in
        yes|YES|y|Y)
            return 0
            ;;
        *)
            echo "Cleanup cancelled."
            exit 0
            ;;
    esac
}

# Cleanup Jenkins from a cluster
cleanup_jenkins() {
    local cluster_name=$1
    local region=$2
    
    print_info "Cleaning up Jenkins from $cluster_name..."
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name >/dev/null 2>&1
    
    # Remove ArgoCD Application first (if it exists)
    print_info "Removing ArgoCD Application..."
    if kubectl get application $ARGOCD_APP_NAME -n $ARGOCD_NAMESPACE --context=$cluster_name >/dev/null 2>&1; then
        kubectl delete application $ARGOCD_APP_NAME -n $ARGOCD_NAMESPACE --context=$cluster_name --timeout=60s
        print_success "ArgoCD Application removed"
    else
        print_info "ArgoCD Application not found (skipping)"
    fi
    
    # Remove Helm release
    print_info "Removing Helm release..."
    if helm status $JENKINS_RELEASE_NAME -n $JENKINS_NAMESPACE --kube-context $cluster_name >/dev/null 2>&1; then
        helm uninstall $JENKINS_RELEASE_NAME -n $JENKINS_NAMESPACE --kube-context $cluster_name --timeout=300s
        print_success "Helm release removed"
    else
        print_info "Helm release not found (skipping)"
    fi
    
    # Wait for LoadBalancer to be cleaned up
    print_info "Waiting for LoadBalancer cleanup..."
    local timeout=60
    local counter=0
    while kubectl get svc -n $JENKINS_NAMESPACE --context=$cluster_name 2>/dev/null | grep -q LoadBalancer 2>/dev/null; do
        if [ $counter -ge $timeout ]; then
            print_warning "LoadBalancer cleanup timeout reached"
            break
        fi
        sleep 5
        counter=$((counter + 5))
    done
    
    # Remove any remaining services manually
    print_info "Removing any remaining services..."
    kubectl delete svc --all -n $JENKINS_NAMESPACE --context=$cluster_name --timeout=60s >/dev/null 2>&1 || true
    
    # Remove PVCs (if any)
    print_info "Removing persistent volume claims..."
    kubectl delete pvc --all -n $JENKINS_NAMESPACE --context=$cluster_name --timeout=60s >/dev/null 2>&1 || true
    
    # Remove storage class (if created by deployment)
    print_info "Removing custom storage class..."
    kubectl delete storageclass ebs-csi-gp3 --context=$cluster_name >/dev/null 2>&1 || true
    
    # Remove namespace (unless keeping it)
    if [ "$KEEP_NAMESPACE" = "false" ]; then
        print_info "Removing namespace..."
        if kubectl get namespace $JENKINS_NAMESPACE --context=$cluster_name >/dev/null 2>&1; then
            kubectl delete namespace $JENKINS_NAMESPACE --context=$cluster_name --timeout=120s
            print_success "Namespace removed"
        else
            print_info "Namespace not found (skipping)"
        fi
    else
        print_info "Keeping namespace as requested"
    fi
    
    # Clean up any remaining finalizers (force cleanup)
    print_info "Cleaning up any stuck resources..."
    kubectl get all -n $JENKINS_NAMESPACE --context=$cluster_name 2>/dev/null | grep jenkins | awk '{print $1}' | xargs -r kubectl delete --context=$cluster_name -n $JENKINS_NAMESPACE --force --grace-period=0 >/dev/null 2>&1 || true
    
    print_success "Jenkins cleanup completed for $cluster_name"
}

# Clean up local files
cleanup_local_files() {
    print_info "Cleaning up local credential files..."
    
    local files_removed=0
    for file in jenkins-credentials-*.txt; do
        if [ -f "$file" ]; then
            rm -f "$file"
            files_removed=$((files_removed + 1))
        fi
    done
    
    # Clean up any temp values files
    rm -f /tmp/jenkins-values-*.yaml 2>/dev/null || true
    
    if [ $files_removed -gt 0 ]; then
        print_success "Removed $files_removed credential file(s)"
    else
        print_info "No credential files found"
    fi
}

# Verify cleanup
verify_cleanup() {
    local cluster_name=$1
    local region=$2
    
    print_info "Verifying cleanup for $cluster_name..."
    
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name >/dev/null 2>&1
    
    local issues=0
    
    # Check ArgoCD Application
    if kubectl get application $ARGOCD_APP_NAME -n $ARGOCD_NAMESPACE --context=$cluster_name >/dev/null 2>&1; then
        print_warning "ArgoCD Application still exists"
        issues=$((issues + 1))
    fi
    
    # Check Helm release
    if helm status $JENKINS_RELEASE_NAME -n $JENKINS_NAMESPACE --kube-context $cluster_name >/dev/null 2>&1; then
        print_warning "Helm release still exists"
        issues=$((issues + 1))
    fi
    
    # Check namespace (if it should be deleted)
    if [ "$KEEP_NAMESPACE" = "false" ] && kubectl get namespace $JENKINS_NAMESPACE --context=$cluster_name >/dev/null 2>&1; then
        print_warning "Namespace still exists"
        issues=$((issues + 1))
    fi
    
    # Check for any LoadBalancer services
    if kubectl get svc -A --context=$cluster_name 2>/dev/null | grep -q "jenkins.*LoadBalancer" 2>/dev/null; then
        print_warning "LoadBalancer services still exist"
        issues=$((issues + 1))
    fi
    
    if [ $issues -eq 0 ]; then
        print_success "Cleanup verification passed for $cluster_name"
        return 0
    else
        print_warning "Cleanup verification found $issues issue(s) for $cluster_name"
        return 1
    fi
}

# Main execution
main() {
    echo "🧹 Jenkins Cleanup Script"
    echo "Target: ${TARGET_CLUSTER:-both clusters}"
    echo "Force: $FORCE_DELETE"
    echo "Keep namespace: $KEEP_NAMESPACE"
    echo ""
    
    confirm_cleanup
    
    local failed_cleanups=0
    local successful_cleanups=()
    
    if [ "$TARGET_CLUSTER" = "east" ]; then
        cleanup_jenkins $EAST_CLUSTER $EAST_REGION
        if verify_cleanup $EAST_CLUSTER $EAST_REGION; then
            successful_cleanups+=("$EAST_CLUSTER")
        else
            failed_cleanups=$((failed_cleanups + 1))
        fi
    elif [ "$TARGET_CLUSTER" = "west" ]; then
        cleanup_jenkins $WEST_CLUSTER $WEST_REGION
        if verify_cleanup $WEST_CLUSTER $WEST_REGION; then
            successful_cleanups+=("$WEST_CLUSTER")
        else
            failed_cleanups=$((failed_cleanups + 1))
        fi
    else
        # Cleanup both clusters
        cleanup_jenkins $EAST_CLUSTER $EAST_REGION
        if verify_cleanup $EAST_CLUSTER $EAST_REGION; then
            successful_cleanups+=("$EAST_CLUSTER")
        else
            failed_cleanups=$((failed_cleanups + 1))
        fi
        
        echo ""
        
        cleanup_jenkins $WEST_CLUSTER $WEST_REGION
        if verify_cleanup $WEST_CLUSTER $WEST_REGION; then
            successful_cleanups+=("$WEST_CLUSTER")
        else
            failed_cleanups=$((failed_cleanups + 1))
        fi
    fi
    
    # Clean up local files
    echo ""
    cleanup_local_files
    
    echo ""
    echo "🎯 Cleanup Summary:"
    if [ $failed_cleanups -eq 0 ]; then
        print_success "Jenkins cleanup completed successfully on all target clusters!"
        echo "Successfully cleaned: ${successful_cleanups[*]}"
    else
        print_warning "Cleanup completed with $failed_cleanups issue(s)"
        if [ ${#successful_cleanups[@]} -gt 0 ]; then
            echo "Successfully cleaned: ${successful_cleanups[*]}"
        fi
        echo ""
        echo "If issues persist, you may need to:"
        echo "1. Check AWS Console for any remaining Load Balancers"
        echo "2. Manually delete stuck resources with kubectl delete --force"
        echo "3. Verify ArgoCD is not recreating resources"
    fi
    
    echo ""
    echo "📋 Manual verification commands:"
    echo "kubectl get all -n $JENKINS_NAMESPACE --context=multi-region-eks-east"
    echo "kubectl get all -n $JENKINS_NAMESPACE --context=multi-region-eks-west"
    echo "kubectl get application $ARGOCD_APP_NAME -n $ARGOCD_NAMESPACE --context=multi-region-eks-east"
    echo "kubectl get application $ARGOCD_APP_NAME -n $ARGOCD_NAMESPACE --context=multi-region-eks-west"
}

main "$@"
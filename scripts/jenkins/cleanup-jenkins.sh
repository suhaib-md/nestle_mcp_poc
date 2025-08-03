#!/bin/bash

# Jenkins Cleanup Script
# Completely removes Jenkins deployment from ArgoCD and Kubernetes

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
JENKINS_NAMESPACE="jenkins"
ARGOCD_NAMESPACE="argocd"
JENKINS_APP_NAME="jenkins-lts"

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

# Cleanup function
cleanup_jenkins() {
    local cluster_name=$1
    local region=$2
    
    print_header "Cleaning up Jenkins on $cluster_name"
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name >/dev/null 2>&1
    
    # Step 1: Delete ArgoCD Application
    print_info "Deleting ArgoCD application..."
    if kubectl get application $JENKINS_APP_NAME -n $ARGOCD_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        kubectl delete application $JENKINS_APP_NAME -n $ARGOCD_NAMESPACE --context $cluster_name --ignore-not-found=true
        print_success "ArgoCD application deleted"
        
        # Wait for application to be fully deleted
        local timeout=60
        local counter=0
        while kubectl get application $JENKINS_APP_NAME -n $ARGOCD_NAMESPACE --context $cluster_name >/dev/null 2>&1 && [ $counter -lt $timeout ]; do
            print_info "Waiting for ArgoCD application to be deleted..."
            sleep 2
            counter=$((counter + 2))
        done
    else
        print_info "ArgoCD application not found"
    fi
    
    # Step 2: Force delete Jenkins resources
    print_info "Deleting Jenkins resources..."
    
    if kubectl get namespace $JENKINS_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        # Delete StatefulSet first to avoid recreation
        kubectl delete statefulset jenkins-lts -n $JENKINS_NAMESPACE --context $cluster_name --ignore-not-found=true --timeout=60s
        
        # Delete services to release load balancers
        kubectl delete svc --all -n $JENKINS_NAMESPACE --context $cluster_name --ignore-not-found=true --timeout=60s
        
        # Delete PVCs to release EBS volumes
        kubectl delete pvc --all -n $JENKINS_NAMESPACE --context $cluster_name --ignore-not-found=true --timeout=60s
        
        # Delete all other resources
        kubectl delete all --all -n $JENKINS_NAMESPACE --context $cluster_name --ignore-not-found=true --timeout=60s
        
        print_success "Jenkins resources deleted"
    else
        print_info "Jenkins namespace not found"
    fi
    
    # Step 3: Delete namespace
    print_info "Deleting Jenkins namespace..."
    if kubectl get namespace $JENKINS_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        kubectl delete namespace $JENKINS_NAMESPACE --context $cluster_name --ignore-not-found=true --timeout=120s
        
        # Wait for namespace deletion with timeout
        local timeout=120
        local counter=0
        while kubectl get namespace $JENKINS_NAMESPACE --context $cluster_name >/dev/null 2>&1 && [ $counter -lt $timeout ]; do
            print_info "Waiting for namespace deletion..."
            sleep 5
            counter=$((counter + 5))
        done
        
        # Force cleanup if namespace is stuck
        if kubectl get namespace $JENKINS_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
            print_warning "Namespace stuck in terminating state, attempting force cleanup..."
            kubectl patch namespace $JENKINS_NAMESPACE --context $cluster_name -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            
            # Wait a bit more
            sleep 10
            if kubectl get namespace $JENKINS_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
                print_warning "Namespace still exists but should be cleaned up eventually"
            else
                print_success "Namespace force-deleted successfully"
            fi
        else
            print_success "Namespace deleted successfully"
        fi
    else
        print_info "Jenkins namespace not found"
    fi
    
    # Step 4: Clean up any stuck EBS volumes (optional)
    print_info "Checking for orphaned EBS volumes..."
    local volumes=$(aws ec2 describe-volumes --region $region --filters "Name=tag:kubernetes.io/cluster/$cluster_name,Values=owned" "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$JENKINS_NAMESPACE" --query 'Volumes[?State==`available`].VolumeId' --output text 2>/dev/null || echo "")
    
    if [ -n "$volumes" ] && [ "$volumes" != "None" ]; then
        print_warning "Found orphaned EBS volumes: $volumes"
        print_info "You may want to manually delete these volumes if they're no longer needed:"
        for volume in $volumes; do
            echo "  aws ec2 delete-volume --region $region --volume-id $volume"
        done
    else
        print_success "No orphaned EBS volumes found"
    fi
    
    # Step 5: Clean up local files
    print_info "Cleaning up local credential files..."
    rm -f "jenkins-credentials-${cluster_name}.txt"
    rm -f "jenkins-url-${cluster_name}.tmp"
    print_success "Local files cleaned up"
    
    print_success "Cleanup completed for $cluster_name"
}

# Verify cleanup
verify_cleanup() {
    local cluster_name=$1
    local region=$2
    
    print_header "Verifying cleanup for $cluster_name"
    
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name >/dev/null 2>&1
    
    # Check ArgoCD application
    if kubectl get application $JENKINS_APP_NAME -n $ARGOCD_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        print_error "ArgoCD application still exists"
    else
        print_success "ArgoCD application removed"
    fi
    
    # Check namespace
    if kubectl get namespace $JENKINS_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        print_warning "Jenkins namespace still exists (may be terminating)"
    else
        print_success "Jenkins namespace removed"
    fi
    
    # Check for any remaining resources
    local remaining_resources=$(kubectl get all -n $JENKINS_NAMESPACE --context $cluster_name 2>/dev/null | wc -l || echo "0")
    if [ "$remaining_resources" -gt "0" ]; then
        print_warning "Some resources may still exist in Jenkins namespace"
        kubectl get all -n $JENKINS_NAMESPACE --context $cluster_name 2>/dev/null || true
    else
        print_success "No remaining Jenkins resources found"
    fi
}

# Main execution
main() {
    local target_cluster=$1
    local skip_verification=${2:-false}
    
    print_header "Jenkins Cleanup Script"
    
    if [ -n "$target_cluster" ]; then
        case $target_cluster in
            $EAST_CLUSTER|east)
                cleanup_jenkins $EAST_CLUSTER $EAST_REGION
                [ "$skip_verification" != "true" ] && verify_cleanup $EAST_CLUSTER $EAST_REGION
                ;;
            $WEST_CLUSTER|west)
                cleanup_jenkins $WEST_CLUSTER $WEST_REGION
                [ "$skip_verification" != "true" ] && verify_cleanup $WEST_CLUSTER $WEST_REGION
                ;;
            *)
                print_error "Unknown cluster: $target_cluster"
                echo "Usage: $0 [east|west|$EAST_CLUSTER|$WEST_CLUSTER] [skip-verification]"
                exit 1
                ;;
        esac
    else
        # Clean up both clusters
        for cluster_info in "$EAST_CLUSTER $EAST_REGION" "$WEST_CLUSTER $WEST_REGION"; do
            local cluster_name=$(echo $cluster_info | cut -d' ' -f1)
            local region=$(echo $cluster_info | cut -d' ' -f2)
            cleanup_jenkins $cluster_name $region
            [ "$skip_verification" != "true" ] && verify_cleanup $cluster_name $region
            echo -e "\n" # Add spacing between clusters
        done
    fi
    
    print_header "Cleanup Complete"
    print_info "Jenkins has been removed from the specified cluster(s)"
    print_info "You can now run the deployment script again if needed"
}

main "$@"

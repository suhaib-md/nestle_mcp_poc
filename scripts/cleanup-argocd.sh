#!/bin/bash

# ArgoCD and Applications Cleanup Script
# Removes all components created by the setup scripts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
EAST_CLUSTER="east-cluster"
WEST_CLUSTER="west-cluster"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

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

# Confirm cleanup
confirm_cleanup() {
    print_header "ArgoCD Complete Cleanup"
    print_warning "This will delete ALL ArgoCD components, applications, and data!"
    echo ""
    echo "Components to be removed:"
    echo "  - ArgoCD installation (both clusters)"
    echo "  - Jenkins deployment and data"
    echo "  - SonarQube deployment and data"
    echo "  - Kyverno installation and policies"
    echo "  - All persistent volumes and data"
    echo "  - LoadBalancer services"
    echo "  - Generated scripts and manifests"
    echo ""
    
    read -p "Are you sure you want to proceed? Type 'yes' to continue: " -r
    if [[ ! $REPLY == "yes" ]]; then
        print_info "Cleanup cancelled"
        exit 0
    fi
    
    print_warning "Starting cleanup in 5 seconds... Press Ctrl+C to cancel"
    sleep 5
}

# Clean applications from ArgoCD
cleanup_argocd_applications() {
    local cluster_name=$1
    
    print_header "Cleaning ArgoCD Applications on $cluster_name"
    
    kubectl config use-context $cluster_name
    
    # Delete ArgoCD applications (this will also remove the managed resources)
    print_info "Deleting ArgoCD applications..."
    kubectl delete application jenkins -n argocd --ignore-not-found=true --timeout=60s
    kubectl delete application sonarqube -n argocd --ignore-not-found=true --timeout=60s
    kubectl delete application kyverno -n argocd --ignore-not-found=true --timeout=60s
    
    # Wait a bit for finalizers to complete
    sleep 30
    
    print_success "ArgoCD applications deleted"
}

# Force cleanup of namespaces and resources
force_cleanup_namespaces() {
    local cluster_name=$1
    
    print_header "Force Cleaning Namespaces on $cluster_name"
    
    kubectl config use-context $cluster_name
    
    # List of namespaces to clean
    local namespaces=("jenkins" "sonarqube" "kyverno" "argocd")
    
    for ns in "${namespaces[@]}"; do
        print_info "Cleaning namespace: $ns"
        
        # First try graceful deletion
        kubectl delete namespace $ns --ignore-not-found=true --timeout=60s &
        local delete_pid=$!
        
        # Wait for graceful deletion or timeout
        sleep 60
        
        # Check if namespace still exists
        if kubectl get namespace $ns >/dev/null 2>&1; then
            print_warning "Namespace $ns still exists, forcing cleanup..."
            
            # Kill the graceful delete process
            kill $delete_pid 2>/dev/null || true
            
            # Remove finalizers from all resources in the namespace
            print_info "Removing finalizers from $ns resources..."
            
            # Get all resources with finalizers and remove them
            for resource in $(kubectl api-resources --verbs=list --namespaced -o name); do
                kubectl get $resource -n $ns -o name 2>/dev/null | while read -r item; do
                    kubectl patch $item -n $ns -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                done
            done
            
            # Force delete the namespace
            kubectl get namespace $ns -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
            kubectl delete namespace $ns --force --grace-period=0 --ignore-not-found=true 2>/dev/null || true
        fi
        
        # Verify namespace is gone
        if kubectl get namespace $ns >/dev/null 2>&1; then
            print_error "Failed to delete namespace $ns"
        else
            print_success "Namespace $ns deleted"
        fi
    done
}

# Clean up persistent volumes
cleanup_persistent_volumes() {
    local cluster_name=$1
    
    print_header "Cleaning Persistent Volumes on $cluster_name"
    
    kubectl config use-context $cluster_name
    
    print_info "Deleting persistent volume claims..."
    kubectl delete pvc --all -n jenkins --ignore-not-found=true --timeout=60s 2>/dev/null || true
    kubectl delete pvc --all -n sonarqube --ignore-not-found=true --timeout=60s 2>/dev/null || true
    
    print_info "Deleting persistent volumes..."
    # Delete PVs that were created for our applications
    kubectl get pv -o json | jq -r '.items[] | select(.spec.claimRef.namespace | test("jenkins|sonarqube")) | .metadata.name' 2>/dev/null | while read -r pv; do
        if [ -n "$pv" ]; then
            print_info "Deleting PV: $pv"
            kubectl patch pv $pv -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            kubectl delete pv $pv --force --grace-period=0 --ignore-not-found=true 2>/dev/null || true
        fi
    done
    
    print_success "Persistent volumes cleaned"
}

# Clean up LoadBalancer services (to prevent AWS charges)
cleanup_loadbalancers() {
    local cluster_name=$1
    
    print_header "Cleaning LoadBalancer Services on $cluster_name"
    
    kubectl config use-context $cluster_name
    
    print_info "Deleting ArgoCD LoadBalancer service..."
    kubectl delete service argocd-server-lb -n argocd --ignore-not-found=true --timeout=60s 2>/dev/null || true
    
    print_info "Checking for other LoadBalancer services..."
    kubectl get svc --all-namespaces --field-selector spec.type=LoadBalancer -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type --no-headers | while read -r ns name type; do
        if [[ "$ns" =~ ^(jenkins|sonarqube|argocd)$ ]]; then
            print_info "Deleting LoadBalancer service: $ns/$name"
            kubectl delete service $name -n $ns --ignore-not-found=true --timeout=60s 2>/dev/null || true
        fi
    done
    
    print_success "LoadBalancer services cleaned"
}

# Clean up Kyverno cluster resources
cleanup_kyverno_cluster_resources() {
    print_header "Cleaning Kyverno Cluster Resources"
    
    # These are cluster-wide resources, so we only need to do this once
    kubectl config use-context $EAST_CLUSTER
    
    print_info "Deleting Kyverno cluster policies..."
    kubectl delete clusterpolicy --all --ignore-not-found=true --timeout=60s 2>/dev/null || true
    kubectl delete cpol --all --ignore-not-found=true --timeout=60s 2>/dev/null || true
    
    print_info "Deleting Kyverno policy exceptions..."
    kubectl delete policyexception --all -n kyverno --ignore-not-found=true --timeout=60s 2>/dev/null || true
    
    print_info "Deleting Kyverno CRDs..."
    kubectl delete crd --ignore-not-found=true \
        clusterpolicies.kyverno.io \
        policies.kyverno.io \
        policyexceptions.kyverno.io \
        generaterequests.kyverno.io \
        updaterequests.kyverno.io \
        admissionreports.wgpolicyk8s.io \
        clusteradmissionreports.wgpolicyk8s.io \
        backgroundscanreports.wgpolicyk8s.io \
        clusterbackgroundscanreports.wgpolicyk8s.io 2>/dev/null || true
    
    print_success "Kyverno cluster resources cleaned"
}

# Clean up generated files and directories
cleanup_generated_files() {
    print_header "Cleaning Generated Files and Directories"
    
    print_info "Removing ArgoCD configuration files..."
    rm -rf "$PROJECT_DIR/argocd" 2>/dev/null || true
    rm -rf "$PROJECT_DIR/argocd-apps" 2>/dev/null || true
    
    print_info "Removing generated scripts..."
    rm -f "$PROJECT_DIR/scripts/verify-argocd-setup.sh" 2>/dev/null || true
    rm -f "$PROJECT_DIR/scripts/"*port-forward*.sh 2>/dev/null || true
    rm -f "$PROJECT_DIR/scripts/"access-*.sh 2>/dev/null || true
    rm -f ./*port-forward*.sh 2>/dev/null || true
    rm -f ./access-*.sh 2>/dev/null || true
    
    print_success "Generated files cleaned"
}

# Check cluster connectivity
check_cluster_connectivity() {
    print_header "Checking Cluster Connectivity"
    
    # Check east cluster
    if kubectl config use-context $EAST_CLUSTER >/dev/null 2>&1; then
        if kubectl get nodes >/dev/null 2>&1; then
            print_success "East cluster accessible"
        else
            print_error "East cluster not accessible"
            return 1
        fi
    else
        print_error "East cluster context not found"
        return 1
    fi
    
    # Check west cluster
    if kubectl config use-context $WEST_CLUSTER >/dev/null 2>&1; then
        if kubectl get nodes >/dev/null 2>&1; then
            print_success "West cluster accessible"
        else
            print_error "West cluster not accessible"
            return 1
        fi
    else
        print_error "West cluster context not found"
        return 1
    fi
}

# Wait for resources to be fully deleted
wait_for_cleanup() {
    print_header "Waiting for Resources to be Fully Deleted"
    
    print_info "Waiting for namespace deletion to complete..."
    
    for cluster in $EAST_CLUSTER $WEST_CLUSTER; do
        kubectl config use-context $cluster
        
        local max_wait=300  # 5 minutes
        local wait_time=0
        
        while [ $wait_time -lt $max_wait ]; do
            local remaining_ns=$(kubectl get ns 2>/dev/null | grep -E "(jenkins|sonarqube|kyverno|argocd)" | wc -l)
            if [ "$remaining_ns" -eq 0 ]; then
                print_success "All namespaces deleted on $cluster"
                break
            fi
            
            print_info "Waiting for $remaining_ns namespaces to be deleted on $cluster..."
            sleep 10
            wait_time=$((wait_time + 10))
        done
        
        if [ $wait_time -ge $max_wait ]; then
            print_warning "Timeout waiting for namespace deletion on $cluster"
        fi
    done
}

# Verify cleanup completion
verify_cleanup() {
    print_header "Verifying Cleanup Completion"
    
    for cluster in $EAST_CLUSTER $WEST_CLUSTER; do
        echo -e "\n${YELLOW}=== $cluster ===${NC}"
        kubectl config use-context $cluster
        
        # Check for remaining namespaces
        local remaining_ns=$(kubectl get ns 2>/dev/null | grep -E "(jenkins|sonarqube|kyverno|argocd)" || true)
        if [ -z "$remaining_ns" ]; then
            print_success "No application namespaces remaining"
        else
            print_warning "Some namespaces still exist:"
            echo "$remaining_ns"
        fi
        
        # Check for remaining PVs
        local remaining_pvs=$(kubectl get pv 2>/dev/null | grep -E "(jenkins|sonarqube)" || true)
        if [ -z "$remaining_pvs" ]; then
            print_success "No application PVs remaining"
        else
            print_warning "Some PVs still exist:"
            echo "$remaining_pvs"
        fi
        
        # Check for LoadBalancer services
        local remaining_lbs=$(kubectl get svc --all-namespaces --field-selector spec.type=LoadBalancer 2>/dev/null | grep -E "(jenkins|sonarqube|argocd)" || true)
        if [ -z "$remaining_lbs" ]; then
            print_success "No application LoadBalancers remaining"
        else
            print_warning "Some LoadBalancers still exist:"
            echo "$remaining_lbs"
        fi
    done
    
    # Check cluster-wide resources
    kubectl config use-context $EAST_CLUSTER
    local remaining_policies=$(kubectl get clusterpolicy --no-headers 2>/dev/null | wc -l)
    if [ "$remaining_policies" -eq 0 ]; then
        print_success "No Kyverno cluster policies remaining"
    else
        print_warning "$remaining_policies cluster policies still exist"
    fi
}

# Main cleanup function
main() {
    print_header "ArgoCD Complete Environment Cleanup"
    
    # Confirm before proceeding
    confirm_cleanup
    
    # Check connectivity first
    if ! check_cluster_connectivity; then
        print_error "Cannot access required clusters. Exiting."
        exit 1
    fi
    
    # Clean up applications first (ArgoCD managed resources)
    cleanup_argocd_applications $EAST_CLUSTER
    cleanup_argocd_applications $WEST_CLUSTER
    
    # Clean up LoadBalancers to prevent charges
    cleanup_loadbalancers $EAST_CLUSTER
    cleanup_loadbalancers $WEST_CLUSTER
    
    # Clean up persistent volumes
    cleanup_persistent_volumes $EAST_CLUSTER
    cleanup_persistent_volumes $WEST_CLUSTER
    
    # Clean up Kyverno cluster resources
    cleanup_kyverno_cluster_resources
    
    # Force cleanup namespaces
    force_cleanup_namespaces $EAST_CLUSTER
    force_cleanup_namespaces $WEST_CLUSTER
    
    # Wait for cleanup to complete
    wait_for_cleanup
    
    # Clean up generated files
    cleanup_generated_files
    
    # Verify cleanup
    verify_cleanup
    
    print_header "Cleanup Complete"
    print_success "All ArgoCD components and applications have been removed"
    print_info "You can now re-run your setup scripts with corrections"
    print_warning "Note: It may take a few minutes for AWS LoadBalancers to be fully terminated"
    
    echo -e "\n${BLUE}Next Steps:${NC}"
    echo "1. Fix any issues in your setup scripts"
    echo "2. Re-run the setup process"
    echo "3. Verify that all AWS resources are cleaned up in your AWS console"
}

# Check if running with --force flag
if [ "$1" = "--force" ]; then
    print_warning "Running in force mode - skipping confirmation"
    main_without_confirm() {
        check_cluster_connectivity || exit 1
        cleanup_argocd_applications $EAST_CLUSTER
        cleanup_argocd_applications $WEST_CLUSTER
        cleanup_loadbalancers $EAST_CLUSTER
        cleanup_loadbalancers $WEST_CLUSTER
        cleanup_persistent_volumes $EAST_CLUSTER
        cleanup_persistent_volumes $WEST_CLUSTER
        cleanup_kyverno_cluster_resources
        force_cleanup_namespaces $EAST_CLUSTER
        force_cleanup_namespaces $WEST_CLUSTER
        wait_for_cleanup
        cleanup_generated_files
        verify_cleanup
        print_success "Force cleanup complete"
    }
    main_without_confirm
else
    main "$@"
fi

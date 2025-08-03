#!/bin/bash

# SonarQube Troubleshooting Script
# Diagnoses common issues with SonarQube deployment in ArgoCD

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
SONARQUBE_NAMESPACE="sonarqube-app"
ARGOCD_NAMESPACE="argocd"
SONARQUBE_APP_NAME="sonarqube-app"

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

# Check cluster connectivity
check_cluster_connectivity() {
    local cluster_name=$1
    local region=$2
    
    print_header "Checking Cluster Connectivity: $cluster_name"
    
    if aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name >/dev/null 2>&1; then
        print_success "Successfully connected to $cluster_name"
    else
        print_error "Failed to connect to $cluster_name"
        return 1
    fi
    
    if kubectl cluster-info --context $cluster_name >/dev/null 2>&1; then
        print_success "Cluster API is accessible"
    else
        print_error "Cluster API is not accessible"
        return 1
    fi
}

# Check ArgoCD status
check_argocd_status() {
    local cluster_name=$1
    
    print_header "Checking ArgoCD Status: $cluster_name"
    
    # Check ArgoCD pods
    local argocd_pods=$(kubectl get pods -n $ARGOCD_NAMESPACE --context $cluster_name --no-headers 2>/dev/null | wc -l)
    if [ "$argocd_pods" -gt 0 ]; then
        print_success "ArgoCD pods found: $argocd_pods"
        kubectl get pods -n $ARGOCD_NAMESPACE --context $cluster_name
    else
        print_error "No ArgoCD pods found"
        return 1
    fi
    
    # Check ArgoCD application
    if kubectl get application $SONARQUBE_APP_NAME -n $ARGOCD_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        print_success "SonarQube ArgoCD application exists"
        local sync_status=$(kubectl get application $SONARQUBE_APP_NAME -n $ARGOCD_NAMESPACE --context $cluster_name -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        local health_status=$(kubectl get application $SONARQUBE_APP_NAME -n $ARGOCD_NAMESPACE --context $cluster_name -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        echo -e "  Sync Status: $sync_status"
        echo -e "  Health Status: $health_status"
    else
        print_warning "SonarQube ArgoCD application not found"
    fi
}

# Check SonarQube namespace and resources
check_sonarqube_resources() {
    local cluster_name=$1
    
    print_header "Checking SonarQube Resources: $cluster_name"
    
    # Check namespace
    if kubectl get namespace $SONARQUBE_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        print_success "SonarQube namespace exists"
    else
        print_warning "SonarQube namespace does not exist"
        return 1
    fi
    
    # Check pods
    local sonarqube_pods=$(kubectl get pods -n $SONARQUBE_NAMESPACE --context $cluster_name --no-headers 2>/dev/null | wc -l)
    if [ "$sonarqube_pods" -gt 0 ]; then
        print_success "SonarQube pods found: $sonarqube_pods"
        kubectl get pods -n $SONARQUBE_NAMESPACE --context $cluster_name
        
        # Check pod details
        echo -e "\nDetailed pod status:"
        kubectl get pods -n $SONARQUBE_NAMESPACE --context $cluster_name -o wide
    else
        print_warning "No SonarQube pods found"
    fi
    
    # Check services
    local sonarqube_services=$(kubectl get svc -n $SONARQUBE_NAMESPACE --context $cluster_name --no-headers 2>/dev/null | wc -l)
    if [ "$sonarqube_services" -gt 0 ]; then
        print_success "SonarQube services found: $sonarqube_services"
        kubectl get svc -n $SONARQUBE_NAMESPACE --context $cluster_name
    else
        print_warning "No SonarQube services found"
    fi
    
    # Check PVCs
    local sonarqube_pvcs=$(kubectl get pvc -n $SONARQUBE_NAMESPACE --context $cluster_name --no-headers 2>/dev/null | wc -l)
    if [ "$sonarqube_pvcs" -gt 0 ]; then
        print_success "SonarQube PVCs found: $sonarqube_pvcs"
        kubectl get pvc -n $SONARQUBE_NAMESPACE --context $cluster_name
    else
        print_info "No SonarQube PVCs found (might be using ephemeral storage)"
    fi
    
    # Check PostgreSQL pods specifically
    local postgres_pods=$(kubectl get pods -n $SONARQUBE_NAMESPACE --context $cluster_name -l app.kubernetes.io/name=postgresql --no-headers 2>/dev/null | wc -l)
    if [ "$postgres_pods" -gt 0 ]; then
        print_success "PostgreSQL pods found: $postgres_pods"
        kubectl get pods -n $SONARQUBE_NAMESPACE --context $cluster_name -l app.kubernetes.io/name=postgresql
    else
        print_warning "No PostgreSQL pods found"
    fi
}

# Check system requirements
check_system_requirements() {
    local cluster_name=$1
    
    print_header "Checking System Requirements: $cluster_name"
    
    # Check if SonarQube pod exists to check sysctl settings
    local sonarqube_pod=$(kubectl get pods -n $SONARQUBE_NAMESPACE --context $cluster_name -l app=sonarqube -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$sonarqube_pod" ]; then
        print_info "Checking sysctl settings on SonarQube pod..."
        
        # Check vm.max_map_count
        local max_map_count=$(kubectl exec $sonarqube_pod -n $SONARQUBE_NAMESPACE --context $cluster_name -- sysctl vm.max_map_count 2>/dev/null | awk '{print $3}' || echo "unknown")
        if [ "$max_map_count" -ge 524288 ] 2>/dev/null; then
            print_success "vm.max_map_count is set correctly: $max_map_count"
        else
            print_error "vm.max_map_count is too low: $max_map_count (required: >= 524288)"
        fi
        
        # Check fs.file-max
        local file_max=$(kubectl exec $sonarqube_pod -n $SONARQUBE_NAMESPACE --context $cluster_name -- sysctl fs.file-max 2>/dev/null | awk '{print $3}' || echo "unknown")
        if [ "$file_max" -ge 131072 ] 2>/dev/null; then
            print_success "fs.file-max is set correctly: $file_max"
        else
            print_error "fs.file-max is too low: $file_max (required: >= 131072)"
        fi
    else
        print_warning "No SonarQube pod found to check system requirements"
    fi
    
    # Check node resources
    print_info "Checking node resources:"
    kubectl top nodes --context $cluster_name 2>/dev/null || print_warning "Unable to get node metrics (metrics-server might not be installed)"
}

# Check EBS CSI driver (for persistence)
check_ebs_csi_driver() {
    local cluster_name=$1
    
    print_header "Checking EBS CSI Driver: $cluster_name"
    
    # Check EBS CSI controller
    local ebs_controller_pods=$(kubectl get pods -n kube-system -l app=ebs-csi-controller --context $cluster_name --no-headers 2>/dev/null | wc -l)
    if [ "$ebs_controller_pods" -gt 0 ]; then
        print_success "EBS CSI controller pods found: $ebs_controller_pods"
        kubectl get pods -n kube-system -l app=ebs-csi-controller --context $cluster_name
    else
        print_error "No EBS CSI controller pods found"
    fi
    
    # Check EBS CSI node driver
    local ebs_node_pods=$(kubectl get pods -n kube-system -l app=ebs-csi-node --context $cluster_name --no-headers 2>/dev/null | wc -l)
    if [ "$ebs_node_pods" -gt 0 ]; then
        print_success "EBS CSI node pods found: $ebs_node_pods"
        kubectl get pods -n kube-system -l app=ebs-csi-node --context $cluster_name
    else
        print_error "No EBS CSI node pods found"
    fi
    
    # Check storage classes
    print_info "Available storage classes:"
    kubectl get storageclass --context $cluster_name
}

# Check events for issues
check_events() {
    local cluster_name=$1
    
    print_header "Checking Recent Events: $cluster_name"
    
    # Check namespace events
    if kubectl get namespace $SONARQUBE_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        print_info "Recent events in SonarQube namespace:"
        kubectl get events -n $SONARQUBE_NAMESPACE --context $cluster_name --sort-by='.lastTimestamp' | tail -15
        
        # Check for specific error patterns
        local volume_errors=$(kubectl get events -n $SONARQUBE_NAMESPACE --context $cluster_name --field-selector reason=FailedAttachVolume 2>/dev/null | grep -c "FailedAttachVolume" || echo "0")
        if [ "$volume_errors" -gt "0" ]; then
            print_error "Found $volume_errors volume attachment errors"
            kubectl get events -n $SONARQUBE_NAMESPACE --context $cluster_name --field-selector reason=FailedAttachVolume
        fi
        
        local scheduling_errors=$(kubectl get events -n $SONARQUBE_NAMESPACE --context $cluster_name --field-selector reason=FailedScheduling 2>/dev/null | grep -c "FailedScheduling" || echo "0")
        if [ "$scheduling_errors" -gt "0" ]; then
            print_error "Found $scheduling_errors scheduling errors"
            kubectl get events -n $SONARQUBE_NAMESPACE --context $cluster_name --field-selector reason=FailedScheduling
        fi
        
        local pull_errors=$(kubectl get events -n $SONARQUBE_NAMESPACE --context $cluster_name --field-selector reason=Failed 2>/dev/null | grep -c "Failed" || echo "0")
        if [ "$pull_errors" -gt "0" ]; then
            print_error "Found $pull_errors failed events"
            kubectl get events -n $SONARQUBE_NAMESPACE --context $cluster_name --field-selector reason=Failed
        fi
    else
        print_info "SonarQube namespace does not exist, checking cluster-wide events:"
        kubectl get events --context $cluster_name --sort-by='.lastTimestamp' | tail -10
    fi
}

# Get pod logs
get_pod_logs() {
    local cluster_name=$1
    
    print_header "Getting Pod Logs: $cluster_name"
    
    if ! kubectl get namespace $SONARQUBE_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        print_warning "SonarQube namespace does not exist"
        return 1
    fi
    
    # Get SonarQube pod logs
    local sonarqube_pod=$(kubectl get pods -n $SONARQUBE_NAMESPACE --context $cluster_name -l app=sonarqube -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$sonarqube_pod" ]; then
        print_info "SonarQube pod logs from: $sonarqube_pod"
        
        local pod_phase=$(kubectl get pod $sonarqube_pod -n $SONARQUBE_NAMESPACE --context $cluster_name -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        print_info "Pod phase: $pod_phase"
        
        # Get init container logs if pod is in Init state
        if [ "$pod_phase" = "Pending" ]; then
            print_info "Pod is in Pending state, checking init containers..."
            local init_containers=$(kubectl get pod $sonarqube_pod -n $SONARQUBE_NAMESPACE --context $cluster_name -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null || echo "")
            for container in $init_containers; do
                print_info "Init container logs for $container:"
                kubectl logs $sonarqube_pod -n $SONARQUBE_NAMESPACE --context $cluster_name -c $container --tail=20 2>/dev/null || print_warning "No logs available for init container $container"
            done
        fi
        
        print_info "Main SonarQube container logs:"
        kubectl logs $sonarqube_pod -n $SONARQUBE_NAMESPACE --context $cluster_name --tail=50 2>/dev/null || print_warning "No logs available for SonarQube container"
        
        # Describe the pod for more details
        print_info "SonarQube pod description:"
        kubectl describe pod $sonarqube_pod -n $SONARQUBE_NAMESPACE --context $cluster_name
    else
        print_warning "No SonarQube pods found"
    fi
    
    # Get PostgreSQL pod logs
    local postgres_pod=$(kubectl get pods -n $SONARQUBE_NAMESPACE --context $cluster_name -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$postgres_pod" ]; then
        print_info "PostgreSQL pod logs from: $postgres_pod"
        kubectl logs $postgres_pod -n $SONARQUBE_NAMESPACE --context $cluster_name --tail=30 2>/dev/null || print_warning "No logs available for PostgreSQL container"
    else
        print_warning "No PostgreSQL pods found"
    fi
}

# Provide recommendations
provide_recommendations() {
    local cluster_name=$1
    
    print_header "Recommendations for $cluster_name"
    
    print_info "Common solutions:"
    echo "1. If SonarQube fails with sysctl errors:"
    echo "   - Ensure init containers have privileged security context"
    echo "   - Check if the cluster supports privileged init containers"
    echo ""
    echo "2. If PostgreSQL connection fails:"
    echo "   - Check PostgreSQL pod status and logs"
    echo "   - Verify database credentials in values file"
    echo "   - Ensure PostgreSQL service is accessible"
    echo ""
    echo "3. If EBS volume attachment fails:"
    echo "   - Run: ./scripts/sonarqube/cleanup-sonarqube.sh $cluster_name"
    echo "   - Then: ./scripts/sonarqube/deploy-sonarqube.sh $cluster_name"
    echo ""
    echo "4. If ArgoCD sync fails:"
    echo "   - Check ArgoCD server logs: kubectl logs -n argocd deployment/argocd-server --context $cluster_name"
    echo "   - Manually sync: kubectl patch application sonarqube-app -n argocd --context $cluster_name --type merge -p '{\"operation\":{\"sync\":{}}}}'"
    echo ""
    echo "5. If pods are stuck in Pending:"
    echo "   - Check node resources: kubectl top nodes --context $cluster_name"
    echo "   - Check node taints: kubectl get nodes --context $cluster_name -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints"
    echo "   - Verify tolerations match node taints"
    echo ""
    echo "6. Memory issues:"
    echo "   - SonarQube requires at least 2GB RAM"
    echo "   - PostgreSQL needs additional 512MB-1GB"
    echo "   - Check if nodes have sufficient memory"
    echo ""
    echo "7. For immediate deployment without persistence:"
    echo "   - Run: ./scripts/sonarqube/deploy-sonarqube.sh $cluster_name"
}

# Main troubleshooting function
troubleshoot_cluster() {
    local cluster_name=$1
    local region=$2
    
    print_header "Troubleshooting SonarQube on $cluster_name"
    
    check_cluster_connectivity $cluster_name $region || return 1
    check_argocd_status $cluster_name
    check_sonarqube_resources $cluster_name
    check_system_requirements $cluster_name
    check_ebs_csi_driver $cluster_name
    check_events $cluster_name
    get_pod_logs $cluster_name
    provide_recommendations $cluster_name
}

# Main execution
main() {
    local target_cluster=$1
    
    print_header "SonarQube Deployment Troubleshooting"
    
    if [ -n "$target_cluster" ]; then
        case $target_cluster in
            $EAST_CLUSTER|east)
                troubleshoot_cluster $EAST_CLUSTER $EAST_REGION
                ;;
            $WEST_CLUSTER|west)
                troubleshoot_cluster $WEST_CLUSTER $WEST_REGION
                ;;
            *)
                print_error "Unknown cluster: $target_cluster"
                echo "Usage: $0 [east|west|$EAST_CLUSTER|$WEST_CLUSTER]"
                exit 1
                ;;
        esac
    else
        # Troubleshoot both clusters
        for cluster_info in "$EAST_CLUSTER $EAST_REGION" "$WEST_CLUSTER $WEST_REGION"; do
            local cluster_name=$(echo $cluster_info | cut -d' ' -f1)
            local region=$(echo $cluster_info | cut -d' ' -f2)
            troubleshoot_cluster $cluster_name $region
            echo -e "\n" # Add spacing between clusters
        done
    fi
    
    print_header "Troubleshooting Complete"
    print_info "If issues persist, check the manual deployment script: ./scripts/sonarqube/deploy-sonarqube.sh"
}

main "$@"

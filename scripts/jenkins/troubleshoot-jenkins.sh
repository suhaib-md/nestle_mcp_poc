#!/bin/bash

# Jenkins Troubleshooting Script
# Diagnoses common issues with Jenkins deployment in ArgoCD

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
    if kubectl get application $JENKINS_APP_NAME -n $ARGOCD_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        print_success "Jenkins ArgoCD application exists"
        local sync_status=$(kubectl get application $JENKINS_APP_NAME -n $ARGOCD_NAMESPACE --context $cluster_name -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        local health_status=$(kubectl get application $JENKINS_APP_NAME -n $ARGOCD_NAMESPACE --context $cluster_name -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        echo -e "  Sync Status: $sync_status"
        echo -e "  Health Status: $health_status"
    else
        print_warning "Jenkins ArgoCD application not found"
    fi
}

# Check Jenkins namespace and resources
check_jenkins_resources() {
    local cluster_name=$1
    
    print_header "Checking Jenkins Resources: $cluster_name"
    
    # Check namespace
    if kubectl get namespace $JENKINS_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        print_success "Jenkins namespace exists"
    else
        print_warning "Jenkins namespace does not exist"
        return 1
    fi
    
    # Check pods
    local jenkins_pods=$(kubectl get pods -n $JENKINS_NAMESPACE --context $cluster_name --no-headers 2>/dev/null | wc -l)
    if [ "$jenkins_pods" -gt 0 ]; then
        print_success "Jenkins pods found: $jenkins_pods"
        kubectl get pods -n $JENKINS_NAMESPACE --context $cluster_name
        
        # Check pod details
        local pod_name=$(kubectl get pods -n $JENKINS_NAMESPACE --context $cluster_name -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$pod_name" ]; then
            echo -e "\nPod Status Details:"
            kubectl get pod $pod_name -n $JENKINS_NAMESPACE --context $cluster_name -o wide
        fi
    else
        print_warning "No Jenkins pods found"
    fi
    
    # Check services
    local jenkins_services=$(kubectl get svc -n $JENKINS_NAMESPACE --context $cluster_name --no-headers 2>/dev/null | wc -l)
    if [ "$jenkins_services" -gt 0 ]; then
        print_success "Jenkins services found: $jenkins_services"
        kubectl get svc -n $JENKINS_NAMESPACE --context $cluster_name
    else
        print_warning "No Jenkins services found"
    fi
    
    # Check PVCs
    local jenkins_pvcs=$(kubectl get pvc -n $JENKINS_NAMESPACE --context $cluster_name --no-headers 2>/dev/null | wc -l)
    if [ "$jenkins_pvcs" -gt 0 ]; then
        print_success "Jenkins PVCs found: $jenkins_pvcs"
        kubectl get pvc -n $JENKINS_NAMESPACE --context $cluster_name
    else
        print_info "No Jenkins PVCs found (might be using ephemeral storage)"
    fi
}

# Check EBS CSI driver
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
    if kubectl get namespace $JENKINS_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        print_info "Recent events in Jenkins namespace:"
        kubectl get events -n $JENKINS_NAMESPACE --context $cluster_name --sort-by='.lastTimestamp' | tail -10
        
        # Check for specific error patterns
        local volume_errors=$(kubectl get events -n $JENKINS_NAMESPACE --context $cluster_name --field-selector reason=FailedAttachVolume 2>/dev/null | grep -c "FailedAttachVolume" || echo "0")
        if [ "$volume_errors" -gt "0" ]; then
            print_error "Found $volume_errors volume attachment errors"
            kubectl get events -n $JENKINS_NAMESPACE --context $cluster_name --field-selector reason=FailedAttachVolume
        fi
        
        local scheduling_errors=$(kubectl get events -n $JENKINS_NAMESPACE --context $cluster_name --field-selector reason=FailedScheduling 2>/dev/null | grep -c "FailedScheduling" || echo "0")
        if [ "$scheduling_errors" -gt "0" ]; then
            print_error "Found $scheduling_errors scheduling errors"
            kubectl get events -n $JENKINS_NAMESPACE --context $cluster_name --field-selector reason=FailedScheduling
        fi
    else
        print_info "Jenkins namespace does not exist, checking cluster-wide events:"
        kubectl get events --context $cluster_name --sort-by='.lastTimestamp' | tail -10
    fi
}

# Get pod logs
get_pod_logs() {
    local cluster_name=$1
    
    print_header "Getting Pod Logs: $cluster_name"
    
    if ! kubectl get namespace $JENKINS_NAMESPACE --context $cluster_name >/dev/null 2>&1; then
        print_warning "Jenkins namespace does not exist"
        return 1
    fi
    
    local pod_name=$(kubectl get pods -n $JENKINS_NAMESPACE --context $cluster_name -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$pod_name" ]; then
        print_warning "No Jenkins pods found"
        return 1
    fi
    
    print_info "Getting logs from pod: $pod_name"
    
    # Get init container logs if pod is in Init state
    local pod_phase=$(kubectl get pod $pod_name -n $JENKINS_NAMESPACE --context $cluster_name -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$pod_phase" = "Pending" ]; then
        print_info "Pod is in Pending state, checking init containers..."
        local init_containers=$(kubectl get pod $pod_name -n $JENKINS_NAMESPACE --context $cluster_name -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null || echo "")
        for container in $init_containers; do
            print_info "Init container logs for $container:"
            kubectl logs $pod_name -n $JENKINS_NAMESPACE --context $cluster_name -c $container --tail=20 2>/dev/null || print_warning "No logs available for init container $container"
        done
    else
        print_info "Main container logs:"
        kubectl logs $pod_name -n $JENKINS_NAMESPACE --context $cluster_name --tail=50 2>/dev/null || print_warning "No logs available"
    fi
    
    # Describe the pod for more details
    print_info "Pod description:"
    kubectl describe pod $pod_name -n $JENKINS_NAMESPACE --context $cluster_name
}

# Provide recommendations
provide_recommendations() {
    local cluster_name=$1
    
    print_header "Recommendations for $cluster_name"
    
    print_info "Common solutions:"
    echo "1. If EBS volume attachment fails:"
    echo "   - Run: ./scripts/jenkins/cleanup-jenkins.sh $cluster_name"
    echo "   - Then: ./scripts/jenkins/deploy-jenkins-manual.sh $cluster_name --no-persistence"
    echo ""
    echo "2. If ArgoCD sync fails:"
    echo "   - Check ArgoCD server logs: kubectl logs -n argocd deployment/argocd-server --context $cluster_name"
    echo "   - Manually sync: kubectl patch application jenkins-lts -n argocd --context $cluster_name --type merge -p '{\"operation\":{\"sync\":{}}}'"
    echo ""
    echo "3. If pods are stuck in Pending:"
    echo "   - Check node resources: kubectl top nodes --context $cluster_name"
    echo "   - Check node taints: kubectl get nodes --context $cluster_name -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints"
    echo ""
    echo "4. For immediate deployment without persistence:"
    echo "   - Run: ./scripts/jenkins/deploy-jenkins-manual.sh $cluster_name --no-persistence"
}

# Main troubleshooting function
troubleshoot_cluster() {
    local cluster_name=$1
    local region=$2
    
    print_header "Troubleshooting Jenkins on $cluster_name"
    
    check_cluster_connectivity $cluster_name $region || return 1
    check_argocd_status $cluster_name
    check_jenkins_resources $cluster_name
    check_ebs_csi_driver $cluster_name
    check_events $cluster_name
    get_pod_logs $cluster_name
    provide_recommendations $cluster_name
}

# Main execution
main() {
    local target_cluster=$1
    
    print_header "Jenkins Deployment Troubleshooting"
    
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
    print_info "If issues persist, check the manual deployment script: ./scripts/jenkins/deploy-jenkins.sh"
}

main "$@"

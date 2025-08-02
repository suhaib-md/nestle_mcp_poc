#!/bin/bash

# EKS Add-ons Testing Script
# Tests all add-ons (CoreDNS, EBS CSI, NGINX Ingress, Crossplane) on both regions

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Default to test both clusters
TEST_EAST=true
TEST_WEST=true

# Usage function
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -e, --east-only    Test only the east cluster"
    echo "  -w, --west-only    Test only the west cluster"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                 # Test both clusters"
    echo "  $0 --east-only     # Test only east cluster"
    echo "  $0 --west-only     # Test only west cluster"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--east-only)
            TEST_EAST=true
            TEST_WEST=false
            shift
            ;;
        -w|--west-only)
            TEST_EAST=false
            TEST_WEST=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

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

# Test CoreDNS
test_coredns() {
    local cluster_name=$1
    local region=$2
    
    print_header "Testing CoreDNS on $cluster_name"
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name > /dev/null 2>&1
    
    # Apply DNS resolution test
    kubectl apply -f "$PROJECT_DIR/tests/coredns/dns-resolution-test.yaml" --context $cluster_name
    
    # Wait for pod to be ready and then complete
    kubectl wait --for=condition=ready --timeout=60s pod/coredns-test --context $cluster_name
    
    # Wait a bit for the test to complete
    sleep 10
    
    # Get logs
    local logs=$(kubectl logs pod/coredns-test --context $cluster_name)
    
    # Check if test passed
    if echo "$logs" | grep -q "=== CoreDNS Test Completed Successfully ==="; then
        print_success "CoreDNS test passed on $cluster_name"
        echo "$logs"
    else
        print_error "CoreDNS test failed on $cluster_name"
        echo "$logs"
        return 1
    fi
    
    # Cleanup
    kubectl delete pod coredns-test --context $cluster_name --ignore-not-found=true
}

# Test EBS CSI Driver
test_ebs_csi() {
    local cluster_name=$1
    local region=$2
    
    print_header "Testing EBS CSI Driver on $cluster_name"
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name > /dev/null 2>&1
    
    # Apply storage test
    kubectl apply -f "$PROJECT_DIR/tests/ebs-csi/storage-test.yaml" --context $cluster_name
    
    # Wait for PVC to be bound
    kubectl wait --for=condition=bound --timeout=120s pvc/ebs-test-pvc --context $cluster_name
    
    # Wait for pod to be ready and then complete
    kubectl wait --for=condition=ready --timeout=120s pod/ebs-test-pod --context $cluster_name
    
    # Wait a bit for the test to complete
    sleep 10
    
    # Get logs
    local logs=$(kubectl logs pod/ebs-test-pod --context $cluster_name)
    
    # Check if test passed
    if echo "$logs" | grep -q "=== EBS CSI Driver Test Completed Successfully ==="; then
        print_success "EBS CSI Driver test passed on $cluster_name"
        echo "$logs"
    else
        print_error "EBS CSI Driver test failed on $cluster_name"
        echo "$logs"
        return 1
    fi
    
    # Cleanup
    kubectl delete -f "$PROJECT_DIR/tests/ebs-csi/storage-test.yaml" --context $cluster_name --ignore-not-found=true
}

# Test NGINX Ingress
test_nginx_ingress() {
    local cluster_name=$1
    local region=$2
    
    print_header "Testing NGINX Ingress on $cluster_name"
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name > /dev/null 2>&1
    
    # Apply ingress test
    kubectl apply -f "$PROJECT_DIR/tests/nginx-ingress/ingress-test.yaml" --context $cluster_name
    
    # Wait for deployment to be ready
    kubectl wait --for=condition=available --timeout=120s deployment/nginx-test-app --context $cluster_name
    
    # Wait for ingress to get an address
    print_info "Waiting for load balancer to be provisioned..."
    local timeout=300
    local counter=0
    local lb_hostname=""
    
    while [ $counter -lt $timeout ]; do
        lb_hostname=$(kubectl get ingress nginx-test-ingress --context $cluster_name -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [ -n "$lb_hostname" ]; then
            break
        fi
        sleep 10
        counter=$((counter + 10))
        echo "⏳ Waiting for load balancer... ($counter/$timeout seconds)"
    done
    
    if [ -n "$lb_hostname" ]; then
        print_success "NGINX Ingress test passed on $cluster_name - Load balancer: $lb_hostname"
        
        # Check if NGINX Ingress Controller is running
        local nginx_pods=$(kubectl get pods -n ingress-nginx --context $cluster_name -l app.kubernetes.io/component=controller --no-headers 2>/dev/null | wc -l)
        if [ "$nginx_pods" -gt 0 ]; then
            print_success "NGINX Ingress Controller is running on $cluster_name"
        else
            print_warning "NGINX Ingress Controller pods not found on $cluster_name"
        fi
    else
        print_error "NGINX Ingress test failed on $cluster_name - Load balancer not provisioned"
        return 1
    fi
    
    # Cleanup
    kubectl delete -f "$PROJECT_DIR/tests/nginx-ingress/ingress-test.yaml" --context $cluster_name --ignore-not-found=true
}

# Setup Crossplane IRSA
setup_crossplane_irsa() {
    local cluster_name=$1
    local region=$2
    
    print_info "Setting up Crossplane with IRSA for $cluster_name"
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name > /dev/null 2>&1
    
    # Apply Crossplane deployment with IRSA
    kubectl apply -f "$PROJECT_DIR/addons/crossplane/crossplane-simple.yaml" --context $cluster_name
    
    # Wait for Crossplane to be ready
    kubectl wait --for=condition=available --timeout=300s deployment/crossplane -n crossplane-system --context $cluster_name
    
    # Install AWS provider and ProviderConfig
    kubectl apply -f "$PROJECT_DIR/addons/crossplane/aws-provider-config.yaml" --context $cluster_name
    
    # Wait for provider to be installed
    kubectl wait --for=condition=installed --timeout=300s provider/provider-aws --context $cluster_name
    
    # Wait for provider to be healthy
    kubectl wait --for=condition=healthy --timeout=300s provider/provider-aws --context $cluster_name
    
    # Get the AWS provider service account name
    local provider_sa=$(kubectl get pods -n crossplane-system --context $cluster_name -l pkg.crossplane.io/provider=provider-aws -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null || echo "")
    
    if [ -n "$provider_sa" ]; then
        print_info "Annotating service account $provider_sa with IAM role"
        kubectl annotate serviceaccount $provider_sa -n crossplane-system --context $cluster_name eks.amazonaws.com/role-arn=arn:aws:iam::888752476777:role/CrossplaneEBSRole --overwrite
        
        # Restart provider pod to pick up annotation
        kubectl delete pod -n crossplane-system --context $cluster_name -l pkg.crossplane.io/provider=provider-aws
        kubectl wait --for=condition=ready --timeout=120s pod -n crossplane-system --context $cluster_name -l pkg.crossplane.io/provider=provider-aws
    else
        print_error "Could not find AWS provider service account"
        return 1
    fi
}

# Test Crossplane EBS Volume
test_crossplane() {
    local cluster_name=$1
    local region=$2
    
    print_header "Testing Crossplane EBS Volume on $cluster_name"
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name > /dev/null 2>&1
    
    # Setup Crossplane IRSA if needed
    local crossplane_pods=$(kubectl get pods -n crossplane-system --context $cluster_name -l app=crossplane --no-headers 2>/dev/null | wc -l)
    if [ "$crossplane_pods" -eq 0 ]; then
        setup_crossplane_irsa $cluster_name $region
    fi
    
    # Clean up any existing test volume
    kubectl delete volume crossplane-ebs-test --context $cluster_name --ignore-not-found=true
    sleep 5
    
    # Choose the appropriate test manifest based on region
    local test_manifest="$PROJECT_DIR/tests/crossplane/ebs-volume-test.yaml"
    if [ "$region" = "us-west-2" ]; then
        test_manifest="$PROJECT_DIR/tests/crossplane/ebs-volume-test-west.yaml"
    fi
    
    # Apply the test volume
    kubectl apply -f "$test_manifest" --context $cluster_name
    
    # Wait for volume to be synced (created in AWS)
    print_info "Waiting for volume to be synced with AWS..."
    local timeout=120
    local counter=0
    while [ $counter -lt $timeout ]; do
        local synced=$(kubectl get volume crossplane-ebs-test --context $cluster_name -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || echo "Unknown")
        if [ "$synced" = "True" ]; then
            print_success "Volume is synced with AWS!"
            break
        elif [ "$synced" = "False" ]; then
            print_error "Volume sync failed. Checking details..."
            kubectl describe volume crossplane-ebs-test --context $cluster_name
            return 1
        else
            echo "⏳ Waiting for volume sync... ($counter/$timeout seconds)"
            sleep 5
            counter=$((counter + 5))
        fi
    done
    
    if [ $counter -ge $timeout ]; then
        print_error "Timeout waiting for volume to be synced"
        kubectl describe volume crossplane-ebs-test --context $cluster_name
        return 1
    fi
    
    # Get the AWS EBS volume ID
    local volume_id=$(kubectl get volume crossplane-ebs-test --context $cluster_name -o jsonpath='{.status.atProvider.volumeID}')
    if [ -n "$volume_id" ]; then
        print_success "EBS Volume created with ID: $volume_id"
        
        # Verify in AWS
        print_info "Verifying volume in AWS..."
        aws ec2 describe-volumes --volume-ids $volume_id --region $region --query 'Volumes[0].{VolumeId:VolumeId,State:State,Size:Size,VolumeType:VolumeType,AvailabilityZone:AvailabilityZone}' --output table
        
        print_success "Crossplane EBS volume test passed on $cluster_name"
        print_success "IRSA (IAM Roles for Service Accounts) is working correctly"
        print_success "Crossplane can create AWS resources using the assigned IAM role"
    else
        print_error "Could not retrieve EBS volume ID"
        kubectl describe volume crossplane-ebs-test --context $cluster_name
        return 1
    fi
    
    # Cleanup
    kubectl delete volume crossplane-ebs-test --context $cluster_name --ignore-not-found=true
}

# Test single cluster
test_cluster() {
    local cluster_name=$1
    local region=$2
    
    print_header "Testing EKS Cluster: $cluster_name ($region)"
    
    local failed_tests=0
    
    # Test CoreDNS
    if ! test_coredns $cluster_name $region; then
        failed_tests=$((failed_tests + 1))
    fi
    
    # Test EBS CSI Driver
    if ! test_ebs_csi $cluster_name $region; then
        failed_tests=$((failed_tests + 1))
    fi
    
    # Test NGINX Ingress
    if ! test_nginx_ingress $cluster_name $region; then
        failed_tests=$((failed_tests + 1))
    fi
    
    # Test Crossplane
    if ! test_crossplane $cluster_name $region; then
        failed_tests=$((failed_tests + 1))
    fi
    
    if [ $failed_tests -eq 0 ]; then
        print_success "All tests passed on $cluster_name"
        return 0
    else
        print_error "$failed_tests test(s) failed on $cluster_name"
        return 1
    fi
}

# Main execution
main() {
    print_header "EKS Add-ons Testing Suite"
    
    local total_failures=0
    
    # Test East cluster
    if [ "$TEST_EAST" = true ]; then
        if ! test_cluster $EAST_CLUSTER $EAST_REGION; then
            total_failures=$((total_failures + 1))
        fi
    fi
    
    # Test West cluster
    if [ "$TEST_WEST" = true ]; then
        if ! test_cluster $WEST_CLUSTER $WEST_REGION; then
            total_failures=$((total_failures + 1))
        fi
    fi
    
    # Final summary
    print_header "Test Summary"
    
    if [ $total_failures -eq 0 ]; then
        print_success "All addon tests completed successfully!"
        echo ""
        echo "✅ CoreDNS: DNS resolution working"
        echo "✅ EBS CSI Driver: Persistent storage working"
        echo "✅ NGINX Ingress: Load balancing working"
        echo "✅ Crossplane: Infrastructure as Code working with IRSA"
        echo ""
        print_info "All EKS add-ons are functioning correctly across the tested clusters."
    else
        print_error "Some tests failed. Please check the output above for details."
        exit 1
    fi
}

# Run main function
main "$@"

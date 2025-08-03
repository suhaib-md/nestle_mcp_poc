#!/bin/bash

# SonarQube with RDS Cleanup Script
# This script cleans up SonarQube deployment and RDS resources

set -e

# Configuration
EAST_CLUSTER="multi-region-eks-east"
WEST_CLUSTER="multi-region-eks-west"
EAST_REGION="us-east-1"
WEST_REGION="us-west-2"
SONARQUBE_NAMESPACE="sonarqube-app"
CROSSPLANE_NAMESPACE="crossplane-system"

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
KEEP_RDS=false

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
        --keep-rds)
            KEEP_RDS=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [east|west] [--keep-rds]"
            echo "  east/west: Clean up specific cluster only"
            echo "  --keep-rds: Keep RDS instance (only clean up SonarQube)"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Cleanup SonarQube from a cluster
cleanup_sonarqube() {
    local cluster_name=$1
    local region=$2
    
    print_info "Cleaning up SonarQube from $cluster_name..."
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name >/dev/null 2>&1
    
    # Delete ArgoCD application
    kubectl delete application sonarqube-app -n argocd --context=$cluster_name >/dev/null 2>&1 || true
    
    # Delete SonarQube resources
    kubectl delete namespace $SONARQUBE_NAMESPACE --context=$cluster_name >/dev/null 2>&1 || true
    
    print_success "SonarQube cleaned up from $cluster_name"
}

# Cleanup RDS resources
cleanup_rds() {
    local cluster_name=$1
    local region=$2
    
    if [ "$KEEP_RDS" = "true" ]; then
        print_info "Keeping RDS instance (--keep-rds flag used)"
        return 0
    fi
    
    print_info "Cleaning up RDS resources..."
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name >/dev/null 2>&1
    
    # Delete RDS instance
    kubectl delete dbinstance sonarqube-postgres -n $CROSSPLANE_NAMESPACE --context=$cluster_name >/dev/null 2>&1 || true
    
    # Delete DB subnet group
    kubectl delete dbsubnetgroup sonarqube-subnet-group -n $CROSSPLANE_NAMESPACE --context=$cluster_name >/dev/null 2>&1 || true
    
    # Clean up security group
    local vpc_id=$(aws eks describe-cluster --name $cluster_name --region $region --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")
    if [ -n "$vpc_id" ] && [ "$vpc_id" != "None" ]; then
        local sg_id=$(aws ec2 describe-security-groups --region $region \
            --filters "Name=group-name,Values=sonarqube-rds-sg" "Name=vpc-id,Values=$vpc_id" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
        
        if [ "$sg_id" != "None" ]; then
            aws ec2 delete-security-group --region $region --group-id $sg_id >/dev/null 2>&1 || true
            print_info "Deleted RDS security group: $sg_id"
        fi
    fi
    
    print_success "RDS resources cleaned up"
}

# Cleanup from a single cluster
cleanup_cluster() {
    local cluster_name=$1
    local region=$2
    
    print_info "Cleaning up $cluster_name..."
    
    cleanup_sonarqube $cluster_name $region
    cleanup_rds $cluster_name $region
    
    print_success "Cleanup completed for $cluster_name"
}

# Main execution
main() {
    echo "🧹 SonarQube with RDS Cleanup Script"
    echo "Target: ${TARGET_CLUSTER:-both clusters}"
    echo "Keep RDS: $KEEP_RDS"
    echo ""
    
    print_warning "This will delete SonarQube and potentially RDS resources!"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "Cleanup cancelled"
        exit 0
    fi
    
    if [ "$TARGET_CLUSTER" = "east" ]; then
        cleanup_cluster $EAST_CLUSTER $EAST_REGION
    elif [ "$TARGET_CLUSTER" = "west" ]; then
        cleanup_cluster $WEST_CLUSTER $WEST_REGION
    else
        # Cleanup both clusters
        cleanup_cluster $EAST_CLUSTER $EAST_REGION
        echo ""
        cleanup_cluster $WEST_CLUSTER $WEST_REGION
    fi
    
    # Clean up local files
    rm -f sonarqube-credentials-*.txt
    
    echo ""
    print_success "Cleanup completed successfully!"
}

main "$@"

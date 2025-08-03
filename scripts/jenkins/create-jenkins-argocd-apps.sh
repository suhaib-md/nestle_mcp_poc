#!/bin/bash

# Create ArgoCD Applications for Jenkins deployments
# This script creates ArgoCD applications to manage existing Jenkins deployments

set -e

# Configuration
EAST_CLUSTER="multi-region-eks-east"
WEST_CLUSTER="multi-region-eks-west"
EAST_REGION="us-east-1"
WEST_REGION="us-west-2"
JENKINS_NAMESPACE="jenkins-app"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

# Create ArgoCD Application for a cluster
create_argocd_app() {
    local cluster_name=$1
    local region=$2
    
    print_info "Creating ArgoCD Application for Jenkins on $cluster_name..."
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $region --name $cluster_name --alias $cluster_name >/dev/null 2>&1
    
    # Create ArgoCD Application
    cat <<EOF | kubectl apply --context=$cluster_name -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jenkins-lts
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.jenkins.io
    chart: jenkins
    targetRevision: 5.5.2
    helm:
      values: |
        controller:
          admin:
            username: "admin"
            password: "Jenkins123!"
          serviceType: LoadBalancer
          serviceAnnotations:
            service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
            service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              cpu: "2000m"
              memory: "4Gi"
          tolerations:
            - key: "CriticalAddonsOnly"
              operator: "Exists"
              effect: "NoSchedule"
            - key: "karpenter.sh/disrupted"
              operator: "Exists"
              effect: "NoSchedule"
        
        persistence:
          enabled: false
        
        serviceAccount:
          create: true
          name: jenkins
        
        rbac:
          create: true
  destination:
    server: https://kubernetes.default.svc
    namespace: $JENKINS_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF
    
    print_success "ArgoCD Application created for $cluster_name"
}

# Main execution
main() {
    local target_cluster=$1
    
    echo "🚀 Creating ArgoCD Applications for Jenkins"
    echo ""
    
    if [ "$target_cluster" = "east" ]; then
        create_argocd_app $EAST_CLUSTER $EAST_REGION
    elif [ "$target_cluster" = "west" ]; then
        create_argocd_app $WEST_CLUSTER $WEST_REGION
    else
        # Create for both clusters
        create_argocd_app $EAST_CLUSTER $EAST_REGION
        echo ""
        create_argocd_app $WEST_CLUSTER $WEST_REGION
    fi
    
    echo ""
    print_success "ArgoCD Applications created successfully!"
    echo ""
    echo "📋 Check status with:"
    echo "kubectl get application jenkins-lts -n argocd --context=multi-region-eks-east"
    echo "kubectl get application jenkins-lts -n argocd --context=multi-region-eks-west"
}

main "$@"

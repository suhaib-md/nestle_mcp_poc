#!/bin/bash

set -euo pipefail

# Define your clusters and regions
declare -A CLUSTERS
CLUSTERS=(
  ["us-east-1"]="multi-region-eks-east"
  ["us-west-2"]="multi-region-eks-west"
)

DAEMONSET="ebs-csi-node"
NAMESPACE="kube-system"

for REGION in "${!CLUSTERS[@]}"; do
  CLUSTER_NAME="${CLUSTERS[$REGION]}"

  echo "==============================="
  echo "🔄 Switching to cluster: $CLUSTER_NAME in $REGION"
  echo "==============================="

  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

  echo "⚙️  Patching DaemonSet: $DAEMONSET in namespace $NAMESPACE"

  # Step 1: Add tolerations
  echo "🔧 Adding tolerations..."
  kubectl -n $NAMESPACE patch daemonset $DAEMONSET --type='merge' -p='
spec:
  template:
    spec:
      tolerations:
        - key: "karpenter.sh/disrupted"
          operator: "Exists"
          effect: "NoSchedule"
        - key: "CriticalAddonsOnly"
          operator: "Exists"
          effect: "NoSchedule"
' || echo "⚠️  Failed to patch tolerations. Continuing..."

  # Step 2: Remove affinity if present
  echo "🧹 Removing affinity..."
  kubectl -n $NAMESPACE patch daemonset $DAEMONSET --type='json' -p='[
    {
      "op": "remove",
      "path": "/spec/template/spec/affinity"
    }
  ]' || echo "⚠️  Affinity section not found or already removed."

  # Step 3: Wait for rollout
  echo "🚀 Waiting for DaemonSet rollout..."
  kubectl rollout status daemonset $DAEMONSET -n $NAMESPACE

  # Step 4: List running pods
  echo "📦 Verifying pods for $CLUSTER_NAME..."
  kubectl get pods -n $NAMESPACE -l app=$DAEMONSET -o wide

  echo "✅ Fix applied successfully to $CLUSTER_NAME in $REGION"
  echo
done

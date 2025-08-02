#!/bin/bash

echo "🔍 Verifying Multi-Region EKS Setup"
echo "==================================="
echo ""

# Check EKS clusters
echo "📊 EKS Clusters:"
echo "  us-east-1:"
aws eks describe-cluster --region us-east-1 --name multi-region-eks-east --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}' --output table 2>/dev/null || echo "    ❌ Cluster not found or not accessible"

echo "  us-west-2:"
aws eks describe-cluster --region us-west-2 --name multi-region-eks-west --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}' --output table 2>/dev/null || echo "    ❌ Cluster not found or not accessible"

echo ""

# Check VPC Peering
echo "🔗 VPC Peering Connections:"
aws ec2 describe-vpc-peering-connections --region us-east-1 --filters "Name=status-code,Values=active" --query 'VpcPeeringConnections[?Tags[?Key==`Name` && Value==`EKS-MultiRegion-Peering`]].{ID:VpcPeeringConnectionId,Status:Status.Code,RequesterVPC:RequesterVpcInfo.VpcId,AccepterVPC:AccepterVpcInfo.VpcId}' --output table 2>/dev/null

echo ""

# Check kubectl contexts
echo "⚙️  Kubectl Contexts:"
kubectl config get-contexts | grep -E "(east-cluster|west-cluster)" || echo "  ❌ No EKS contexts found"

echo ""

# Test cluster connectivity
echo "🧪 Testing Cluster Connectivity:"
echo "  Testing us-east-1 cluster..."
kubectl --context=east-cluster get nodes 2>/dev/null && echo "    ✅ us-east-1 cluster accessible" || echo "    ❌ us-east-1 cluster not accessible"

echo "  Testing us-west-2 cluster..."
kubectl --context=west-cluster get nodes 2>/dev/null && echo "    ✅ us-west-2 cluster accessible" || echo "    ❌ us-west-2 cluster not accessible"

echo ""
echo "✅ Verification complete!"

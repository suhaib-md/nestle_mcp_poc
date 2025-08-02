#!/bin/bash

echo "🚀 Multi-Region EKS Cluster Setup"
echo "=================================="
echo ""

# Step 1: Monitor cluster creation
echo "Step 1: Monitoring EKS cluster deployment..."
echo "This typically takes 15-20 minutes to complete."
echo ""

while true; do
    echo "$(date): Checking stack status..."
    
    # Check us-east-1 stack
    east_status=$(aws cloudformation describe-stacks --region us-east-1 --stack-name eks-multi-region-eks-east-stack --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
    
    # Check us-west-2 stack
    west_status=$(aws cloudformation describe-stacks --region us-west-2 --stack-name eks-multi-region-eks-west-stack --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
    
    echo "  us-east-1: $east_status"
    echo "  us-west-2: $west_status"
    
    if [[ "$east_status" == "CREATE_COMPLETE" && "$west_status" == "CREATE_COMPLETE" ]]; then
        echo ""
        echo "✅ Both EKS clusters have been successfully created!"
        break
    elif [[ "$east_status" == "CREATE_FAILED" || "$west_status" == "CREATE_FAILED" ]]; then
        echo ""
        echo "❌ One or more stacks failed to create. Please check the CloudFormation console for details."
        exit 1
    else
        echo "  Still in progress... waiting 60 seconds"
        echo ""
        sleep 60
    fi
done

# Step 2: Setup VPC Peering
echo ""
echo "Step 2: Setting up VPC Peering..."
echo "================================"

# Get VPC IDs and Route Table IDs from both regions
echo "Getting VPC and Route Table information..."

# us-east-1 information
EAST_VPC_ID=$(aws cloudformation describe-stacks --region us-east-1 --stack-name eks-multi-region-eks-east-stack --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text)
EAST_ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --region us-east-1 --filters "Name=vpc-id,Values=$EAST_VPC_ID" "Name=tag:Name,Values=*Private*" --query 'RouteTables[0].RouteTableId' --output text)

# us-west-2 information  
WEST_VPC_ID=$(aws cloudformation describe-stacks --region us-west-2 --stack-name eks-multi-region-eks-west-stack --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text)
WEST_ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --region us-west-2 --filters "Name=vpc-id,Values=$WEST_VPC_ID" "Name=tag:Name,Values=*Private*" --query 'RouteTables[0].RouteTableId' --output text)

echo "East VPC ID: $EAST_VPC_ID"
echo "East Route Table ID: $EAST_ROUTE_TABLE_ID"
echo "West VPC ID: $WEST_VPC_ID"
echo "West Route Table ID: $WEST_ROUTE_TABLE_ID"

# Create VPC Peering Connection
echo "Creating VPC Peering Connection..."
PEERING_CONNECTION_ID=$(aws ec2 create-vpc-peering-connection \
    --region us-east-1 \
    --vpc-id $EAST_VPC_ID \
    --peer-vpc-id $WEST_VPC_ID \
    --peer-region us-west-2 \
    --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
    --output text)

echo "VPC Peering Connection ID: $PEERING_CONNECTION_ID"

# Accept the peering connection in us-west-2
echo "Accepting VPC Peering Connection in us-west-2..."
aws ec2 accept-vpc-peering-connection \
    --region us-west-2 \
    --vpc-peering-connection-id $PEERING_CONNECTION_ID

# Wait for peering connection to be active
echo "Waiting for peering connection to become active..."
sleep 10

# Add routes
echo "Adding route from us-east-1 to us-west-2..."
aws ec2 create-route \
    --region us-east-1 \
    --route-table-id $EAST_ROUTE_TABLE_ID \
    --destination-cidr-block 10.1.0.0/16 \
    --vpc-peering-connection-id $PEERING_CONNECTION_ID

echo "Adding route from us-west-2 to us-east-1..."
aws ec2 create-route \
    --region us-west-2 \
    --route-table-id $WEST_ROUTE_TABLE_ID \
    --destination-cidr-block 10.0.0.0/16 \
    --vpc-peering-connection-id $PEERING_CONNECTION_ID

# Step 3: Configure kubectl
echo ""
echo "Step 3: Configuring kubectl..."
echo "============================="

echo "Updating kubeconfig for us-east-1 cluster..."
aws eks update-kubeconfig --region us-east-1 --name multi-region-eks-east --alias east-cluster

echo "Updating kubeconfig for us-west-2 cluster..."
aws eks update-kubeconfig --region us-west-2 --name multi-region-eks-west --alias west-cluster

# Step 4: Display summary
echo ""
echo "🎉 Multi-Region EKS Setup Complete!"
echo "==================================="
echo ""
echo "📋 Summary:"
echo "  • EKS Cluster (us-east-1): multi-region-eks-east"
echo "  • EKS Cluster (us-west-2): multi-region-eks-west"
echo "  • Kubernetes Version: 1.33"
echo "  • VPC CIDR (us-east-1): 10.0.0.0/16"
echo "  • VPC CIDR (us-west-2): 10.1.0.0/16"
echo "  • VPC Peering Connection: $PEERING_CONNECTION_ID"
echo ""
echo "🔧 Next Steps:"
echo "  • Switch between clusters: kubectl config use-context east-cluster"
echo "  • Switch between clusters: kubectl config use-context west-cluster"
echo "  • Test connectivity: kubectl get nodes"
echo ""
echo "💰 Cost Optimization:"
echo "  • Both clusters use EKS Auto Mode (minimal cost)"
echo "  • No managed node groups (uses Fargate when needed)"
echo "  • VPC Peering has minimal data transfer costs"

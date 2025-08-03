#!/bin/bash

set -e

CLUSTER_NAME="multi-region-eks-east"
REGION="us-east-1"

echo "🔍 Finding EC2 instances for cluster $CLUSTER_NAME..."

# Use tag instead of platform-details to find Bottlerocket instances
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -z "$INSTANCE_IDS" ]; then
  echo "❌ No EC2 instances found for cluster: $CLUSTER_NAME"
  exit 1
fi

echo "✅ Found instances: $INSTANCE_IDS"

echo "🔐 Attaching AmazonSSMManagedInstanceCore policy to node instance role..."

# Get IAM instance profile ARN from the first instance
NODE_ROLE_ARN=$(aws ec2 describe-instances \
  --instance-ids $(echo $INSTANCE_IDS | awk '{print $1}') \
  --query "Reservations[].Instances[].IamInstanceProfile.Arn" \
  --output text)

# Extract role name
NODE_ROLE_NAME=$(aws iam get-instance-profile \
  --instance-profile-name $(basename "$NODE_ROLE_ARN") \
  --query "InstanceProfile.Roles[0].RoleName" \
  --output text)

# Attach the SSM policy
aws iam attach-role-policy \
  --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

#echo "🔄 Rebooting EC2 instances to apply role changes..."
#aws ec2 reboot-instances --instance-ids $INSTANCE_IDS

echo "⏳ Waiting for instances to register with SSM..."

for i in {1..20}; do
  SSM_IDS=$(aws ssm describe-instance-information \
    --query "InstanceInformationList[].InstanceId" \
    --output text)

  MATCHING_IDS=""
  for ID in $INSTANCE_IDS; do
    if echo "$SSM_IDS" | grep -q "$ID"; then
      MATCHING_IDS="$MATCHING_IDS $ID"
    fi
  done

  if [ -n "$MATCHING_IDS" ]; then
    echo "✅ SSM registered instances: $MATCHING_IDS"
    break
  fi

  echo "⏳ Waiting for SSM registration... ($i/20)"
  sleep 15
done

if [ -z "$MATCHING_IDS" ]; then
  echo "❌ No nodes registered with SSM. Aborting."
  exit 1
fi

for ID in $MATCHING_IDS; do
  echo "⚙️ Sending IMDS enable command to $ID..."
  aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --targets "Key=instanceIds,Values=$ID" \
    --parameters 'commands=["apiclient set settings.network.imds_enabled=true", "systemctl restart apid"]' \
    --region "$REGION"
done

echo "✅ IMDS successfully enabled on Bottlerocket nodes!"

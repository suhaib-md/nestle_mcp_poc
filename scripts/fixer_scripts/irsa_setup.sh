#!/bin/bash
set -e

# Mapping region to cluster name
declare -A CLUSTER_NAMES
CLUSTER_NAMES["us-east-1"]="multi-region-eks-east"
CLUSTER_NAMES["us-west-2"]="multi-region-eks-west"

SERVICE_ACCOUNT_NAMESPACE="kube-system"
SERVICE_ACCOUNT_NAME="ebs-csi-controller-sa"
IAM_ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole"
POLICY_ARN="arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGIONS=("us-east-1" "us-west-2")

for REGION in "${REGIONS[@]}"; do
  CLUSTER_NAME="${CLUSTER_NAMES[$REGION]}"
  echo "🔧 Processing region: $REGION (cluster: $CLUSTER_NAME)"

  echo "🔍 Getting OIDC provider URL..."
  OIDC_URL=$(aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query "cluster.identity.oidc.issuer" \
    --output text)

  if [[ "$OIDC_URL" == "null" ]]; then
    echo "❌ OIDC not enabled for cluster: $CLUSTER_NAME in $REGION"
    continue
  fi

  OIDC_HOSTPATH=$(echo "$OIDC_URL" | sed -e "s/^https:\/\///")

  echo "📄 Creating trust policy..."
  cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOSTPATH}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_HOSTPATH}:sub": "system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
        }
      }
    }
  ]
}
EOF

  ROLE_NAME="${IAM_ROLE_NAME}-${REGION}"

  if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "🚀 Creating IAM role: $ROLE_NAME"
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document file://trust-policy.json
  else
    echo "✅ IAM role $ROLE_NAME already exists."
  fi

  echo "🔗 Attaching policy to role..."
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN"

  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

  echo "📌 Annotating service account in cluster $CLUSTER_NAME..."
  kubectl config use-context "arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}" >/dev/null

  kubectl annotate serviceaccount \
    -n "$SERVICE_ACCOUNT_NAMESPACE" \
    "$SERVICE_ACCOUNT_NAME" \
    eks.amazonaws.com/role-arn="$ROLE_ARN" \
    --overwrite

  echo "🔄 Restarting EBS CSI controller in $REGION..."
  kubectl -n "$SERVICE_ACCOUNT_NAMESPACE" rollout restart deployment ebs-csi-controller

  echo "✅ Finished region: $REGION"
done

echo "🎉 IRSA configuration complete for all regions!"

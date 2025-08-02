# Crossplane IRSA (IAM Roles for Service Accounts) Setup

This document describes the complete setup of Crossplane with IRSA for EKS clusters, enabling Crossplane to manage AWS resources using IAM roles instead of static credentials.

## Overview

IRSA allows Kubernetes service accounts to assume AWS IAM roles, providing secure access to AWS services without storing long-term credentials in the cluster.

## Prerequisites

- EKS cluster with OIDC provider configured
- AWS CLI configured with appropriate permissions
- kubectl configured for the target cluster

## Setup Components

### 1. OIDC Provider

The EKS cluster's OIDC provider must be registered in AWS IAM:

```bash
# Get OIDC issuer URL from EKS cluster
OIDC_ISSUER=$(aws eks describe-cluster --name multi-region-eks-east --region us-east-1 --query 'cluster.identity.oidc.issuer' --output text)

# Create OIDC provider
aws iam create-open-id-connect-provider \
  --url $OIDC_ISSUER \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 9e99a48a9960b14926bb7f3b02e22da2b0ab7280 \
  --region us-east-1
```

### 2. IAM Role and Policy

Created IAM role: `CrossplaneEBSRole`
- **Trust Policy**: Allows the Crossplane AWS provider service account to assume the role
- **Permissions Policy**: Grants necessary EBS operations

#### Trust Policy
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::888752476777:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/9F8253D1603051D7E44B0E8F33125B03"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/9F8253D1603051D7E44B0E8F33125B03:sub": "system:serviceaccount:crossplane-system:provider-aws-9420bb96c6f4",
          "oidc.eks.us-east-1.amazonaws.com/id/9F8253D1603051D7E44B0E8F33125B03:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

#### Permissions Policy
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVolume",
        "ec2:DeleteVolume",
        "ec2:DescribeVolumes",
        "ec2:DescribeVolumeStatus",
        "ec2:DescribeVolumeAttribute",
        "ec2:ModifyVolumeAttribute",
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot",
        "ec2:DescribeSnapshots",
        "ec2:DescribeSnapshotAttribute",
        "ec2:ModifySnapshotAttribute",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:DescribeTags",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceAttribute",
        "ec2:DescribeRegions"
      ],
      "Resource": "*"
    }
  ]
}
```

### 3. Crossplane Configuration

#### Service Account Annotation
The AWS provider service account must be annotated with the IAM role ARN:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: provider-aws-9420bb96c6f4
  namespace: crossplane-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::888752476777:role/CrossplaneEBSRole
```

#### ProviderConfig
```yaml
apiVersion: aws.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: InjectedIdentity
```

## Setup Scripts

### Automated Setup
Run the complete setup:
```bash
./scripts/setup-crossplane-irsa.sh
```

### Testing
Test EBS volume creation:
```bash
./scripts/test-crossplane-ebs-improved.sh
```

## Key Implementation Details

### 1. Service Account Discovery
The AWS provider creates its own service account with a generated name (e.g., `provider-aws-9420bb96c6f4`). This service account must be annotated with the IAM role ARN after the provider is installed.

### 2. Trust Policy Updates
When the provider version changes, the service account name changes, requiring updates to the IAM role's trust policy to match the new service account name.

### 3. OIDC Provider Registration
The EKS cluster's OIDC provider must be registered in AWS IAM before IRSA can work. This is a one-time setup per cluster.

### 4. Credential Source
Use `InjectedIdentity` as the credential source in ProviderConfig, not `IRSA` (which is not supported in the current provider version).

## Troubleshooting

### Common Issues

1. **WebIdentityErr: No OpenIDConnect provider found**
   - Solution: Create the OIDC provider in AWS IAM

2. **AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity**
   - Solution: Update the trust policy with the correct service account name

3. **WebIdentityErr: unable to read file**
   - Solution: Ensure the service account has the correct IAM role annotation

### Verification Commands

```bash
# Check OIDC provider
aws iam list-open-id-connect-providers

# Check IAM role
aws iam get-role --role-name CrossplaneEBSRole

# Check service account annotation
kubectl get serviceaccount -n crossplane-system -l pkg.crossplane.io/provider=provider-aws -o yaml

# Check provider status
kubectl get providers

# Check ProviderConfig
kubectl get providerconfig default -o yaml
```

## Test Results

### Successful Test Output
```
=== Crossplane EBS Volume Test Completed Successfully ===
Volume Name: crossplane-ebs-test
AWS Volume ID: vol-00730157614b9847f
✅ IRSA (IAM Roles for Service Accounts) is working correctly
✅ Crossplane can create AWS resources using the assigned IAM role
```

### AWS Verification
```
|               DescribeVolumes               |
+-------------------+-------------------------+
|  AvailabilityZone |  us-east-1a             |
|  Size             |  10                     |
|  State            |  available              |
|  VolumeId         |  vol-00730157614b9847f  |
|  VolumeType       |  gp3                    |
+-------------------+-------------------------+
```

## Security Benefits

1. **No Static Credentials**: No AWS access keys stored in the cluster
2. **Least Privilege**: IAM role has only necessary permissions for EBS operations
3. **Temporary Credentials**: STS tokens are automatically rotated
4. **Audit Trail**: All AWS API calls are logged with the assumed role identity

## Maintenance

### Provider Updates
When updating the AWS provider:
1. Note the new service account name
2. Update the IAM role trust policy
3. Annotate the new service account
4. Restart the provider pod

### Permission Updates
To add new AWS services:
1. Update the IAM policy with additional permissions
2. No changes needed to Crossplane configuration

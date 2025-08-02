# EKS Multi-Region Add-ons Setup

This project contains the complete setup and testing infrastructure for EKS clusters with essential add-ons across multiple AWS regions.

## Directory Structure

```
nestle_mcp_poc/
├── README.md                          # This file
├── infrastructure/                    # EKS cluster and VPC infrastructure
│   ├── eks-us-east-1.yaml            # EKS cluster CloudFormation template (East)
│   ├── eks-us-west-2.yaml            # EKS cluster CloudFormation template (West)
│   ├── vpc-peering.yaml              # VPC peering configuration (East)
│   ├── vpc-peering-west.yaml         # VPC peering configuration (West)
│   └── crossplane-ebs-policy.json    # IAM policy for Crossplane EBS operations
├── addons/                           # Add-on installation manifests
│   ├── coredns/                      # CoreDNS (EKS managed add-on)
│   ├── ebs-csi/                      # EBS CSI Driver (EKS managed add-on)
│   ├── nginx-ingress/                # NGINX Ingress Controller
│   │   └── nginx-ingress-official.yaml
│   └── crossplane/                   # Crossplane infrastructure management
│       ├── crossplane-simple.yaml   # Crossplane deployment with IRSA
│       └── aws-provider-config.yaml # AWS provider and ProviderConfig
├── tests/                           # Test manifests for each add-on
│   ├── coredns/
│   │   └── dns-resolution-test.yaml # DNS resolution test
│   ├── ebs-csi/
│   │   └── storage-test.yaml        # EBS persistent storage test
│   ├── nginx-ingress/
│   │   └── ingress-test.yaml        # Ingress load balancer test
│   └── crossplane/
│       └── ebs-volume-test.yaml     # Crossplane EBS volume creation test
├── scripts/                         # Automation scripts
│   ├── complete-setup.sh            # Complete infrastructure setup
│   ├── verify-setup.sh              # Setup verification
│   ├── test-all-addons.sh           # Unified add-on testing (CoreDNS, EBS CSI, NGINX, Crossplane)
│   └── test-ecr-setup.sh            # ECR multi-region testing
└── docs/                           # Documentation
    ├── addon-installation-summary.md
    └── crossplane-irsa-setup.md    # Crossplane IRSA configuration guide
```

## Installed Add-ons

### 1. CoreDNS
- **Type**: EKS Managed Add-on
- **Version**: v1.12.1-eksbuild.2
- **Purpose**: DNS resolution for Kubernetes services
- **Status**: ✅ Active on both clusters

### 2. EBS CSI Driver
- **Type**: EKS Managed Add-on  
- **Version**: v1.46.0-eksbuild.1
- **Purpose**: Persistent storage using Amazon EBS
- **Status**: ✅ Active on both clusters

### 3. NGINX Ingress Controller
- **Type**: Kubernetes Deployment
- **Version**: v1.11.3
- **Purpose**: HTTP/HTTPS load balancing and ingress
- **Status**: ✅ Running on both clusters

### 4. Crossplane
- **Type**: Kubernetes Deployment
- **Version**: v1.18.1
- **Purpose**: Infrastructure as Code and cloud resource management
- **Status**: ✅ Running on both clusters with IRSA (IAM Roles for Service Accounts)
- **Features**:
  - ✅ IRSA configuration for secure AWS access
  - ✅ EBS volume management
  - ✅ No static AWS credentials required

## ECR Multi-Region Setup

### Amazon ECR Repository
- **Repository Name**: `nestle-multi-region-app`
- **Primary Region**: us-east-1
- **Secondary Region**: us-west-2
- **Features**:
  - ✅ Cross-region replication enabled
  - ✅ Security scanning on push
  - ✅ AES256 encryption
  - ✅ Lifecycle policies configured
  - ✅ High availability across regions

### Repository URIs
- **Primary**: `888752476777.dkr.ecr.us-east-1.amazonaws.com/nestle-multi-region-app`
- **Secondary**: `888752476777.dkr.ecr.us-west-2.amazonaws.com/nestle-multi-region-app`

## Quick Start

### Prerequisites
- AWS CLI configured with appropriate permissions
- kubectl installed and configured
- Access to both EKS clusters:
  - `multi-region-eks-east` (us-east-1)
  - `multi-region-eks-west` (us-west-2)

### Running the Complete Test Suite

Execute the unified testing script for all add-ons:

```bash
# Test both clusters (all add-ons)
./scripts/test-all-addons.sh

# Test only east cluster
./scripts/test-all-addons.sh --east-only

# Test only west cluster
./scripts/test-all-addons.sh --west-only
```

### Testing ECR Multi-Region Setup

Execute the ECR testing script separately:

```bash
./scripts/test-ecr-setup.sh
```

This script will:
1. Test ECR repository configuration in both regions
2. Verify cross-region replication setup
3. Test authentication and permissions
4. Validate high availability features
5. Provide usage recommendations and Docker commands

## Test Results

### Expected Outputs

#### Unified Add-on Test Success
```
=== Test Summary ===
✅ All addon tests completed successfully!

✅ CoreDNS: DNS resolution working
✅ EBS CSI Driver: Persistent storage working
✅ NGINX Ingress: Load balancing working
✅ Crossplane: Infrastructure as Code working with IRSA

ℹ️  All EKS add-ons are functioning correctly across the tested clusters.
```

#### CoreDNS Test Success
```
=== CoreDNS Test Starting ===
Testing internal DNS resolution...
Server:     172.20.0.10
Address:    172.20.0.10:53

Name:   kubernetes.default.svc.cluster.local
Address: 172.20.0.1

Testing external DNS resolution...
Name:   google.com
Address: 142.251.167.113
=== CoreDNS Test Completed Successfully ===
```

#### EBS CSI Driver Test Success
```
=== EBS CSI Driver Test Starting ===
Writing test data to EBS volume...
Reading test data from EBS volume...
EBS CSI Driver test data - Fri Aug  1 15:30:00 UTC 2025
=== EBS CSI Driver Test Completed Successfully ===
```

#### NGINX Ingress Test Success
```
✅ NGINX Ingress test passed on multi-region-eks-east - Load balancer: k8s-ingressn-ingressn-[hash].elb.us-east-1.amazonaws.com
✅ NGINX Ingress Controller is running on multi-region-eks-east
```

#### Crossplane EBS Volume Test Success
```
✅ EBS Volume created with ID: vol-00730157614b9847f
|               DescribeVolumes               |
+-------------------+-------------------------+
|  AvailabilityZone |  us-east-1a             |
|  Size             |  10                     |
|  State            |  available              |
|  VolumeId         |  vol-00730157614b9847f  |
|  VolumeType       |  gp3                    |
+-------------------+-------------------------+
✅ Crossplane EBS volume test passed on multi-region-eks-east
✅ IRSA (IAM Roles for Service Accounts) is working correctly
✅ Crossplane can create AWS resources using the assigned IAM role
```

## Key Features

### Security
- **IRSA Integration**: Crossplane uses IAM Roles for Service Accounts, eliminating the need for static AWS credentials
- **Least Privilege**: IAM roles have only necessary permissions for specific operations
- **Temporary Credentials**: STS tokens are automatically rotated

### High Availability
- **Multi-Region Setup**: Infrastructure spans us-east-1 and us-west-2
- **Cross-Region Replication**: ECR repositories replicate across regions
- **Load Balancing**: NGINX Ingress provides external access with AWS Load Balancers

### Infrastructure as Code
- **Crossplane**: Manage AWS resources declaratively through Kubernetes
- **CloudFormation**: EKS clusters and VPC infrastructure defined as code
- **Automated Testing**: Comprehensive test suite validates all components

## Troubleshooting

### Common Issues

1. **Pod Pending Due to Node Taints**
   - EKS Auto Mode nodes have taints that require tolerations
   - Test manifests include appropriate tolerations

2. **EBS CSI PVC Binding Issues**
   - Known issue with topology configuration in EKS Auto Mode
   - Driver components are verified to be running

3. **Load Balancer Provisioning Delays**
   - AWS load balancers can take 2-5 minutes to become available
   - Test script includes appropriate wait times

4. **Crossplane IRSA Issues**
   - Ensure OIDC provider is created for the EKS cluster
   - Verify IAM role trust policy matches the service account
   - Check service account annotation with IAM role ARN

### Verification Commands

```bash
# Check cluster connectivity
kubectl cluster-info

# Check add-on status (EKS managed)
aws eks describe-addon --cluster-name multi-region-eks-east --addon-name coredns --region us-east-1
aws eks describe-addon --cluster-name multi-region-eks-east --addon-name aws-ebs-csi-driver --region us-east-1

# Check pod status
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl get pods -n kube-system -l app=ebs-csi-controller
kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller
kubectl get pods -n crossplane-system -l app=crossplane

# Check services and ingress
kubectl get svc -n ingress-nginx
kubectl get ingress --all-namespaces

# Check Crossplane resources
kubectl get providers
kubectl get providerconfig
kubectl get volumes
```

## Cleanup

To remove test resources:
```bash
# Clean up test pods and resources (done automatically by test script)
kubectl delete pods,pvc,ingress,deployment,service,job -l test=coredns
kubectl delete pods,pvc,ingress,deployment,service,job -l test=ebs-csi
kubectl delete pods,pvc,ingress,deployment,service,job -l test=nginx-ingress
kubectl delete volumes --all
```

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review logs using `kubectl logs` commands
3. Verify cluster and add-on status using verification commands
4. Consult the comprehensive documentation in `docs/`

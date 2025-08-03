# SonarQube Deployment Scripts - Multi-Region EKS

## 📋 Overview

This collection provides scripts to deploy SonarQube to your multi-region EKS clusters using Helm and manage them with ArgoCD, following the same successful pattern used for Jenkins.

## 🗂️ Script Files

Create these scripts in your `scripts/sonarqube/` directory:

### 1. `deploy-sonarqube.sh`
- **Purpose**: Main deployment script for SonarQube using Helm
- **Features**: 
  - Deploys SonarQube with embedded PostgreSQL database
  - Configures LoadBalancer with AWS NLB
  - Sets appropriate resource limits and tolerations
  - Supports both ephemeral and persistent storage

### 2. `create-sonarqube-argocd-apps.sh`
- **Purpose**: Creates ArgoCD Applications to manage SonarQube deployments
- **Features**:
  - Creates ArgoCD Application manifests
  - Enables automated sync and self-healing
  - Uses same Helm chart configuration as direct deployment

### 3. `cleanup-sonarqube.sh`
- **Purpose**: Complete cleanup of SonarQube resources
- **Features**:
  - Removes ArgoCD Applications
  - Uninstalls Helm releases
  - Cleans up namespaces, PVCs, and LoadBalancers
  - Includes safety prompts and verification

### 4. `troubleshoot-sonarqube.sh`
- **Purpose**: Comprehensive troubleshooting and diagnostics
- **Features**:
  - Checks system requirements (sysctl settings)
  - Diagnoses PostgreSQL connectivity
  - Analyzes pod logs and events
  - Provides specific recommendations

## 🚀 Quick Start Guide

### Step 1: Create Directory Structure
```bash
mkdir -p scripts/sonarqube
cd scripts/sonarqube
```

### Step 2: Create the Script Files
Copy each script content from the artifacts above into the respective files:
- `deploy-sonarqube.sh`
- `create-sonarqube-argocd-apps.sh`
- `cleanup-sonarqube.sh`
- `troubleshoot-sonarqube.sh`

### Step 3: Make Scripts Executable
```bash
chmod +x *.sh
```

### Step 4: Deploy SonarQube
```bash
# Deploy to both clusters (ephemeral storage)
./deploy-sonarqube.sh

# Deploy to specific cluster
./deploy-sonarqube.sh east
./deploy-sonarqube.sh west

# Deploy with persistent storage (if EBS CSI is working)
./deploy-sonarqube.sh --with-persistence
```

### Step 5: Add ArgoCD Management
```bash
# Add ArgoCD management for both clusters
./create-sonarqube-argocd-apps.sh

# Add for specific cluster
./create-sonarqube-argocd-apps.sh east
./create-sonarqube-argocd-apps.sh west
```

## 📊 Configuration Details

### Default Settings
- **Namespace**: `sonarqube-app`
- **Admin User**: `admin`
- **Admin Password**: `SonarQube123!`
- **PostgreSQL Password**: `SonarPostgres123!`
- **Service Type**: LoadBalancer (AWS NLB)
- **CPU Request**: 500m, Limit: 2000m
- **Memory Request**: 2Gi, Limit: 4Gi
- **PostgreSQL Resources**: 250m CPU, 512Mi Memory

### System Requirements
SonarQube automatically configures required sysctl settings:
- `vm.max_map_count=524288`
- `fs.file-max=131072`

### Persistent Storage
- **Default**: Disabled (ephemeral storage)
- **With Persistence**: 20Gi EBS volumes for SonarQube and PostgreSQL
- **Storage Class**: `ebs-csi-gp3` (created automatically)

## 🛠️ Management Commands

### Deployment Management
```bash
# Check deployment status
helm status sonarqube-app -n sonarqube-app --kube-context multi-region-eks-east
kubectl get pods -n sonarqube-app --context multi-region-eks-east

# Check ArgoCD application
kubectl get application sonarqube-app -n argocd --context multi-region-eks-east
```

### Troubleshooting
```bash
# Run comprehensive diagnostics
./troubleshoot-sonarqube.sh

# Troubleshoot specific cluster
./troubleshoot-sonarqube.sh east
./troubleshoot-sonarqube.sh west

# Check specific components
kubectl logs -n sonarqube-app -l app=sonarqube --context multi-region-eks-east
kubectl logs -n sonarqube-app -l app.kubernetes.io/name=postgresql --context multi-region-eks-east
```

### Cleanup
```bash
# Complete cleanup (with confirmation)
./cleanup-sonarqube.sh

# Force cleanup without prompts
./cleanup-sonarqube.sh --force

# Clean specific cluster only
./cleanup-sonarqube.sh east --force

# Keep namespace during cleanup
./cleanup-sonarqube.sh --keep-namespace
```

## 🔧 Common Issues & Solutions

### 1. Init Container Privilege Issues
If SonarQube fails to start due to sysctl settings:
- Ensure your EKS cluster supports privileged init containers
- Check that security policies allow privileged containers

### 2. PostgreSQL Connection Issues
- Check PostgreSQL pod status: `kubectl get pods -n sonarqube-app -l app.kubernetes.io/name=postgresql`
- Verify database credentials in the Helm values
- Check service connectivity between SonarQube and PostgreSQL

### 3. Memory Issues
- SonarQube requires minimum 2GB RAM
- Ensure cluster nodes have sufficient memory
- Check resource requests vs available node capacity

### 4. LoadBalancer Provisioning
- Verify AWS Load Balancer Controller is installed
- Check AWS IAM permissions for EKS service account
- Monitor AWS Console for Load Balancer creation

### 5. ArgoCD Sync Issues
- Check ArgoCD server logs: `kubectl logs -n argocd deployment/argocd-server`
- Manually trigger sync: `kubectl patch application sonarqube-app -n argocd --type merge -p '{"operation":{"sync":{}}}'`

## 📋 Script Summary Table

| Script | Purpose | Usage Examples |
|--------|---------|---------------|
| `deploy-sonarqube.sh` | Deploy SonarQube via Helm | `./deploy-sonarqube.sh [east\|west] [--with-persistence]` |
| `create-sonarqube-argocd-apps.sh` | Create ArgoCD Applications | `./create-sonarqube-argocd-apps.sh [east\|west]` |
| `cleanup-sonarqube.sh` | Remove all SonarQube resources | `./cleanup-sonarqube.sh [east\|west] [--force] [--keep-namespace]` |
| `troubleshoot-sonarqube.sh` | Diagnose deployment issues | `./troubleshoot-sonarqube.sh [east\|west]` |

## 🎯 Post-Deployment Steps

After successful deployment:

1. **Access SonarQube**: Use the LoadBalancer URLs provided in the deployment output
2. **Change Default Password**: Log in with admin/SonarQube123! and change the password
3. **Configure Projects**: Set up your code analysis projects
4. **Quality Gates**: Configure quality gates for your CI/CD pipeline
5. **Integration**: Connect SonarQube with your Jenkins for automated code analysis

## 🔗 Integration with Jenkins

Once both Jenkins and SonarQube are deployed:
- Install SonarQube Scanner plugin in Jenkins
- Configure SonarQube server connection in Jenkins Global Configuration
- Add SonarQube analysis steps to your Jenkins pipelines

## 📝 Notes

- All scripts follow the same pattern as your successful Jenkins deployment
- Uses the official SonarSource Helm chart
- Configured for EKS Auto Mode with appropriate tolerations
- Credentials are saved to local files for reference
- Scripts include comprehensive error handling and verification

The scripts are ready to use and should work seamlessly with your existing ArgoCD setup!
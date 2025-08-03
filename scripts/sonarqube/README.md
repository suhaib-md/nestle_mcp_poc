# SonarQube with RDS Deployment

This directory contains scripts and manifests to deploy SonarQube with an external RDS PostgreSQL database using Crossplane.

## Overview

This solution provides:
- **SonarQube Community Edition** running in Kubernetes
- **RDS PostgreSQL** database managed by Crossplane
- **LoadBalancer** service for external access
- **ArgoCD integration** for GitOps management
- **Automated deployment** and cleanup scripts

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   LoadBalancer  │    │   SonarQube     │    │   RDS Postgres  │
│   (NLB)         │───▶│   Pod           │───▶│   (Crossplane)  │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         │                       │                       │
    Internet                EKS Cluster              AWS RDS
```

## Prerequisites

1. **EKS Cluster** with Crossplane installed
2. **AWS Provider** configured for Crossplane
3. **IAM Permissions** for RDS creation
4. **kubectl** and **AWS CLI** installed
5. **Proper VPC setup** with private subnets

## Files Description

### Scripts
- `deploy-sonarqube-with-rds.sh` - Main deployment script
- `cleanup-sonarqube-rds.sh` - Cleanup script
- `README.md` - This documentation

### Manifests
- `crossplane-rds.yaml` - Crossplane RDS configuration template
- `sonarqube-with-rds.yaml` - SonarQube Kubernetes manifests
- `sonarqube-argocd-app.yaml` - ArgoCD application template

## Quick Start

### 1. Deploy SonarQube with RDS

Deploy to east cluster:
```bash
./deploy-sonarqube-with-rds.sh east
```

Deploy to west cluster:
```bash
./deploy-sonarqube-with-rds.sh west
```

Deploy to both clusters:
```bash
./deploy-sonarqube-with-rds.sh
```

### 2. Access SonarQube

After deployment, the script will output:
- **URL**: LoadBalancer endpoint
- **Username**: `admin`
- **Password**: `admin` (change on first login)

### 3. Cleanup

Clean up everything:
```bash
./cleanup-sonarqube-rds.sh east
```

Keep RDS but remove SonarQube:
```bash
./cleanup-sonarqube-rds.sh east --keep-rds
```

## Detailed Usage

### Deployment Script Options

```bash
./deploy-sonarqube-with-rds.sh [OPTIONS]

Options:
  east|west     Deploy to specific cluster only
  --skip-rds    Skip RDS creation (assume it already exists)
  -h|--help     Show help message
```

### Cleanup Script Options

```bash
./cleanup-sonarqube-rds.sh [OPTIONS]

Options:
  east|west     Clean up specific cluster only
  --keep-rds    Keep RDS instance (only clean up SonarQube)
  -h|--help     Show help message
```

## What the Deployment Does

### 1. RDS Setup
- Creates a **DB Subnet Group** with private subnets
- Creates a **Security Group** for RDS access
- Provisions **RDS PostgreSQL** instance (db.t3.micro)
- Generates **connection credentials** automatically

### 2. SonarQube Deployment
- Creates **namespace** and **configmap**
- Deploys **SonarQube pod** with proper resource limits
- Creates **LoadBalancer service** (NLB)
- Configures **health checks** and **probes**

### 3. Integration
- Creates **connection secret** from Crossplane
- Configures **JDBC connection** to RDS
- Sets up **proper networking** and security

## Configuration Details

### RDS Configuration
- **Instance Class**: db.t3.micro (suitable for development)
- **Engine**: PostgreSQL 13.13
- **Storage**: 20GB GP2, encrypted
- **Backup**: 7 days retention
- **Network**: Private subnets only

### SonarQube Configuration
- **Image**: sonarqube:10.6.0-community
- **Resources**: 1-2GB RAM, 200m-1000m CPU
- **Storage**: EmptyDir (no persistence for simplicity)
- **Database**: External RDS PostgreSQL

### Security
- **RDS**: Private subnets, security group restrictions
- **SonarQube**: Non-root user, security context
- **Network**: LoadBalancer with NLB for better performance

## Troubleshooting

### Common Issues

1. **RDS Creation Timeout**
   - Check Crossplane AWS provider configuration
   - Verify IAM permissions for RDS
   - Check VPC and subnet configuration

2. **SonarQube Connection Issues**
   - Verify connection secret exists
   - Check security group rules
   - Ensure RDS is in same VPC as EKS

3. **LoadBalancer Not Ready**
   - Check AWS Load Balancer Controller
   - Verify service annotations
   - Check node security groups

### Debug Commands

Check RDS status:
```bash
kubectl get dbinstance sonarqube-postgres -n crossplane-system
kubectl describe dbinstance sonarqube-postgres -n crossplane-system
```

Check connection secret:
```bash
kubectl get secret sonarqube-postgres-connection -n sonarqube-app -o yaml
```

Check SonarQube logs:
```bash
kubectl logs deployment/sonarqube -n sonarqube-app
```

Check service status:
```bash
kubectl get svc sonarqube -n sonarqube-app
kubectl describe svc sonarqube -n sonarqube-app
```

## ArgoCD Integration

To set up GitOps management:

1. **Create Git Repository** with manifests
2. **Update ArgoCD application** with your repo URL
3. **Apply ArgoCD application**:
   ```bash
   kubectl apply -f sonarqube-argocd-app.yaml
   ```

## Cost Considerations

### AWS Resources Created
- **RDS db.t3.micro**: ~$13-15/month
- **NLB LoadBalancer**: ~$16-20/month
- **EBS Storage**: ~$2/month for 20GB

### Cost Optimization
- Use **db.t3.micro** for development
- Enable **deletion protection** for production
- Consider **reserved instances** for long-term use

## Security Best Practices

1. **Change default password** immediately
2. **Enable HTTPS** for production
3. **Use private subnets** for RDS
4. **Restrict security groups** to minimum required
5. **Enable RDS encryption** (already configured)
6. **Regular backups** (configured for 7 days)

## Monitoring and Maintenance

### Health Checks
- SonarQube has built-in health endpoints
- Kubernetes probes monitor application health
- RDS has CloudWatch metrics

### Backup Strategy
- RDS automated backups (7 days)
- SonarQube configuration in Git
- Database schema managed by SonarQube

### Updates
- SonarQube: Update image tag in deployment
- RDS: Managed updates during maintenance window
- Crossplane: Update provider versions

## Support and Documentation

- **SonarQube**: https://docs.sonarqube.org/
- **Crossplane**: https://crossplane.io/docs/
- **AWS RDS**: https://docs.aws.amazon.com/rds/
- **ArgoCD**: https://argo-cd.readthedocs.io/

## License

This deployment configuration is provided as-is for educational and development purposes.

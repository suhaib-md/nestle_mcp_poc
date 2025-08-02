#!/bin/bash

# ArgoCD Setup and Application Deployment Script
# Automates the entire ArgoCD setup process for both clusters

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
EAST_CLUSTER="east-cluster"
WEST_CLUSTER="west-cluster"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Utility functions
print_header() {
    echo -e "\n${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found. Please install kubectl."
        exit 1
    fi
    print_success "kubectl found"
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        print_error "helm not found. Please install helm."
        exit 1
    fi
    print_success "helm found"
    
    # Check cluster contexts
    if ! kubectl config get-contexts | grep -q "$EAST_CLUSTER"; then
        print_error "East cluster context '$EAST_CLUSTER' not found"
        exit 1
    fi
    print_success "East cluster context found"
    
    if ! kubectl config get-contexts | grep -q "$WEST_CLUSTER"; then
        print_error "West cluster context '$WEST_CLUSTER' not found"
        exit 1
    fi
    print_success "West cluster context found"
    
    # Check storage class
    for cluster in $EAST_CLUSTER $WEST_CLUSTER; do
        kubectl config use-context $cluster
        if ! kubectl get storageclass gp2 &> /dev/null; then
            print_warning "StorageClass 'gp2' not found in $cluster, creating default gp2 StorageClass"
            kubectl apply -f - << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp2
provisioner: ebs.csi.aws.com
parameters:
  type: gp2
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
            print_success "StorageClass 'gp2' created in $cluster"
        else
            print_success "StorageClass 'gp2' found in $cluster"
        fi
    done
}

# Create directory structure
create_directories() {
    print_header "Creating Directory Structure"
    
    mkdir -p "$PROJECT_DIR/argocd"
    mkdir -p "$PROJECT_DIR/argocd-apps/jenkins"
    mkdir -p "$PROJECT_DIR/argocd-apps/sonarqube"
    mkdir -p "$PROJECT_DIR/argocd-apps/kyverno"
    
    print_success "Directory structure created"
}

# Install ArgoCD on a cluster
install_argocd() {
    local cluster_name=$1
    
    print_header "Installing ArgoCD on $cluster_name"
    
    kubectl config use-context $cluster_name
    
    # Create namespace and install ArgoCD
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    print_info "Waiting for ArgoCD to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    kubectl get statefulsets -n argocd
    kubectl get all -n argocd
    
    print_success "ArgoCD installed on $cluster_name"
}

# Create ArgoCD LoadBalancer service
create_argocd_service() {
    print_header "Creating ArgoCD LoadBalancer Service"
    
    cat > "$PROJECT_DIR/argocd/argocd-server-service.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-lb
  namespace: argocd
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
spec:
  type: LoadBalancer
  ports:
  - name: https
    port: 443
    protocol: TCP
    targetPort: 8080
  - name: grpc
    port: 80
    protocol: TCP
    targetPort: 8080
  selector:
    app.kubernetes.io/component: server
    app.kubernetes.io/name: argocd-server
    app.kubernetes.io/part-of: argocd
EOF
    
    # Apply to both clusters
    kubectl config use-context $EAST_CLUSTER
    kubectl apply -f "$PROJECT_DIR/argocd/argocd-server-service.yaml"
    
    kubectl config use-context $WEST_CLUSTER
    kubectl apply -f "$PROJECT_DIR/argocd/argocd-server-service.yaml"
    
    print_success "ArgoCD LoadBalancer service created"
}

# Create application manifests
create_application_manifests() {
    print_header "Creating Application Manifests"
    
    # Kyverno application
    cat > "$PROJECT_DIR/argocd-apps/kyverno/kyverno-app.yaml" << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://kyverno.github.io/kyverno/
    chart: kyverno
    targetRevision: v3.1.4
    helm:
      values: |
        admissionController:
          replicas: 2
          resources:
            limits:
              memory: 384Mi
              cpu: 500m
            requests:
              cpu: 100m
              memory: 128Mi
        cleanupController:
          enabled: true
          resources:
            limits:
              memory: 256Mi
              cpu: 500m
            requests:
              cpu: 100m
              memory: 128Mi
        reportsController:
          enabled: true
          resources:
            limits:
              memory: 256Mi
              cpu: 500m
            requests:
              cpu: 100m
              memory: 128Mi
        namespace: kyverno
        installCRDs: true
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 5m
EOF

    # Kyverno policy exclusions
    cat > "$PROJECT_DIR/argocd-apps/kyverno/policy-exclusions.yaml" << 'EOF'
apiVersion: kyverno.io/v1
kind: PolicyException
metadata:
  name: jenkins-sonarqube-exceptions
  namespace: kyverno
spec:
  exceptions:
  - policyName: require-non-root-user
    ruleNames:
    - check-runAsNonRoot
  - policyName: disallow-privilege-escalation  
    ruleNames:
    - check-allowPrivilegeEscalation
  match:
    any:
    - resources:
        kinds:
        - Pod
        - Deployment
        - StatefulSet
        namespaces:
        - jenkins
        - sonarqube
        - argocd
        names:
        - "jenkins*"
        - "sonarqube*"
        - "*postgresql*"
---
apiVersion: kyverno.io/v1
kind: PolicyException
metadata:
  name: system-exceptions
  namespace: kyverno
spec:
  exceptions:
  - policyName: require-pod-resources
    ruleNames:
    - validate-resources
  match:
    any:
    - resources:
        kinds:
        - Pod
        namespaces:
        - kube-system
        - ingress-nginx
        - crossplane-system
EOF

    # Jenkins application
    cat > "$PROJECT_DIR/argocd-apps/jenkins/jenkins-app.yaml" << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jenkins
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.jenkins.io
    chart: jenkins
    targetRevision: 5.7.15
    helm:
      values: |
        controller:
          image:
            repository: jenkins/jenkins
            tag: "2.462.3-lts"
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              cpu: "1000m"
              memory: "2Gi"
          javaOpts: "-Xms1g -Xmx1g"
          serviceType: ClusterIP
          ingress:
            enabled: true
            ingressClassName: nginx
            hostName: jenkins.local
            annotations:
              nginx.ingress.kubernetes.io/ssl-redirect: "false"
              nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
          adminUser: admin
          adminPassword: jenkins123!
          installPlugins:
            - kubernetes:4203.v1dd44f5b_1cf9
            - workflow-aggregator:596.v8c21c963d92d
            - git:5.2.2
            - configuration-as-code:1775.v810dc950b_514
          JCasC:
            defaultConfig: true
            configScripts:
              welcome-message: |
                jenkins:
                  systemMessage: Welcome to Jenkins on EKS!
          securityRealm: |-
            local:
              allowsSignup: false
              users:
               - id: admin
                 password: jenkins123!
          authorizationStrategy: |-
            loggedInUsersCanDoAnything:
              allowAnonymousRead: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
          containerSecurityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false
            capabilities:
              drop:
                - ALL
        persistence:
          enabled: true
          storageClass: gp2
          size: 20Gi
        serviceAccount:
          create: true
          name: jenkins
        agent:
          enabled: true
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
  destination:
    server: https://kubernetes.default.svc
    namespace: jenkins
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 5m
EOF

    # SonarQube application
    cat > "$PROJECT_DIR/argocd-apps/sonarqube/sonarqube-app.yaml" << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sonarqube
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://SonarSource.github.io/helm-chart-sonarqube
    chart: sonarqube
    targetRevision: 10.5.0+796
    helm:
      values: |
        image:
          repository: sonarqube
          tag: "10.5.0-community"
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 1000m
            memory: 2Gi
        ingress:
          enabled: true
          ingressClassName: nginx
          hosts:
            - name: sonarqube.local
              path: /
          annotations:
            nginx.ingress.kubernetes.io/ssl-redirect: "false"
            nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
        persistence:
          enabled: true
          storageClass: gp2
          size: 10Gi
        postgresql:
          enabled: true
          auth:
            postgresPassword: sonarqube123!
            database: sonarqube
          primary:
            persistence:
              enabled: true
              storageClass: gp2
              size: 10Gi
            resources:
              requests:
                cpu: 200m
                memory: 512Mi
              limits:
                cpu: 500m
                memory: 1Gi
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          runAsGroup: 1000
          fsGroup: 1000
        containerSecurityContext:
          runAsNonRoot: true
          runAsUser: 1000
          runAsGroup: 1000
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
          capabilities:
            drop:
              - ALL
        env:
          - name: SONAR_ES_BOOTSTRAP_CHECKS_DISABLE
            value: "true"
        sonarProperties:
          sonar.forceAuthentication: false
        account:
          adminPassword: admin123!
          currentAdminPassword: admin
  destination:
    server: https://kubernetes.default.svc
    namespace: sonarqube
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 5m
EOF

    print_success "Application manifests created"
}

# Deploy applications on a cluster
deploy_applications() {
    local cluster_name=$1
    
    print_header "Deploying Applications on $cluster_name"
    
    kubectl config use-context $cluster_name
    
    # Deploy Kyverno first
    print_info "Deploying Kyverno..."
    kubectl apply -f "$PROJECT_DIR/argocd-apps/kyverno/kyverno-app.yaml"
    
    # Wait for Kyverno to be ready
    print_info "Waiting for Kyverno to be ready (this may take a few minutes)..."
    for i in {1..12}; do
        if kubectl wait --for=condition=available --timeout=30s deployment/kyverno-admission-controller -n kyverno 2>/dev/null; then
            print_success "Kyverno admission controller is ready"
            break
        fi
        print_info "Waiting for Kyverno admission controller... ($i/12)"
        sleep 30
    done
    
    # Apply policy exclusions
    print_info "Applying Kyverno policy exclusions..."
    kubectl apply -f "$PROJECT_DIR/argocd-apps/kyverno/policy-exclusions.yaml" || print_warning "Failed to apply policy exclusions, may need manual intervention"
    
    # Deploy Jenkins
    print_info "Deploying Jenkins..."
    kubectl apply -f "$PROJECT_DIR/argocd-apps/jenkins/jenkins-app.yaml"
    
    # Wait for Jenkins to be ready
    print_info "Waiting for Jenkins to be ready..."
    for i in {1..12}; do
        if kubectl wait --for=condition=available --timeout=30s deployment/jenkins -n jenkins 2>/dev/null; then
            print_success "Jenkins is ready"
            break
        fi
        print_info "Waiting for Jenkins... ($i/12)"
        sleep 30
    done
    
    # Deploy SonarQube
    print_info "Deploying SonarQube..."
    kubectl apply -f "$PROJECT_DIR/argocd-apps/sonarqube/sonarqube-app.yaml"
    
    # Wait for SonarQube to be ready
    print_info "Waiting for SonarQube to be ready..."
    for i in {1..12}; do
        if kubectl wait --for=condition=available --timeout=30s statefulset/sonarqube-sonarqube -n sonarqube 2>/dev/null; then
            print_success "SonarQube is ready"
            break
        fi
        print_info "Waiting for SonarQube... ($i/12)"
        sleep 30
    done
    
    print_success "Applications deployed on $cluster_name"
}

# Create additional Kyverno policies
create_security_policies() {
    print_header "Creating Additional Security Policies"
    
    cat > "$PROJECT_DIR/argocd-apps/kyverno/security-policies.yaml" << 'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privilege-escalation
  annotations:
    policies.kyverno.io/title: Disallow Privilege Escalation
    policies.kyverno.io/category: Pod Security Standards (Restricted)
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Privilege escalation should not be allowed. This policy ensures containers
      do not allow privilege escalation.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-allowPrivilegeEscalation
      match:
        any:
        - resources:
            kinds:
            - Pod
      validate:
        message: "Privilege escalation is not allowed"
        pattern:
          spec:
            =(securityContext):
              =(allowPrivilegeEscalation): "false"
            containers:
            - name: "*"
              =(securityContext):
                =(allowPrivilegeEscalation): "false"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-pod-resources
  annotations:
    policies.kyverno.io/title: Require Pod Resources
    policies.kyverno.io/category: Multi-Tenancy
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Pods should have CPU and memory resource requests and limits defined.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-resources
      match:
        any:
        - resources:
            kinds:
            - Pod
      exclude:
        any:
        - resources:
            namespaces:
            - kube-system
            - kube-public
            - kube-node-lease
            - ingress-nginx
            - crossplane-system
      validate:
        message: "Resource requests and limits are required"
        pattern:
          spec:
            containers:
            - name: "*"
              resources:
                requests:
                  memory: "?*"
                  cpu: "?*"
                limits:
                  memory: "?*"
                  cpu: "?*"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-non-root-user
  annotations:
    policies.kyverno.io/title: Require Non-Root User
    policies.kyverno.io/category: Pod Security Standards (Restricted)
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      Containers should run as non-root user. This policy ensures containers
      run with a non-root user ID.
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: check-runAsNonRoot
      match:
        any:
        - resources:
            kinds:
            - Pod
      validate:
        message: "Containers must run as non-root user"
        anyPattern:
        - spec:
            securityContext:
              runAsNonRoot: true
        - spec:
            containers:
            - name: "*"
              securityContext:
                runAsNonRoot: true
EOF

    # Apply security policies to both clusters after Kyverno is ready
    for cluster in $EAST_CLUSTER $WEST_CLUSTER; do
        kubectl config use-context $cluster
        print_info "Applying security policies to $cluster..."
        for i in {1..12}; do
            if kubectl apply -f "$PROJECT_DIR/argocd-apps/kyverno/security-policies.yaml" 2>/dev/null; then
                print_success "Security policies applied to $cluster"
                break
            fi
            print_info "Waiting for Kyverno CRDs to be ready in $cluster... ($i/12)"
            sleep 30
        done
    done
    
    print_success "Security policies created"
}

# Get access information
get_access_info() {
    print_header "Getting Access Information"
    
    for cluster in $EAST_CLUSTER $WEST_CLUSTER; do
        echo -e "\n${YELLOW}=== $cluster ===${NC}"
        kubectl config use-context $cluster
        
        # ArgoCD password
        local argocd_password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "Not available yet")
        
        # ArgoCD URL
        local argocd_url=""
        local argocd_hostname=$(kubectl -n argocd get svc argocd-server-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [ -n "$argocd_hostname" ]; then
            argocd_url="https://$argocd_hostname"
        else
            argocd_url="LoadBalancer provisioning..."
        fi
        
        # NGINX Ingress URL
        local nginx_hostname=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        local nginx_url=""
        if [ -n "$nginx_hostname" ]; then
            nginx_url="http://$nginx_hostname"
        else
            nginx_url="LoadBalancer provisioning..."
        fi
        
        echo "ArgoCD:"
        echo "  URL: $argocd_url"
        echo "  Username: admin"
        echo "  Password: $argocd_password"
        echo ""
        echo "Jenkins:"
        echo "  URL: $nginx_url (Host: jenkins.local)"
        echo "  Username: admin"
        echo "  Password: jenkins123!"
        echo ""
        echo "SonarQube:"
        echo "  URL: $nginx_url (Host: sonarqube.local)"
        echo "  Username: admin"
        echo "  Password: admin123!"
        echo ""
    done
}

# Monitor deployment status
monitor_deployments() {
    print_header "Monitoring Deployment Status"
    
    for cluster in $EAST_CLUSTER $WEST_CLUSTER; do
        echo -e "\n${YELLOW}=== $cluster ===${NC}"
        kubectl config use-context $cluster
        
        echo "ArgoCD Applications:"
        kubectl get applications -n argocd -o wide 2>/dev/null || echo "  No applications found yet"
        
        echo ""
        echo "Jenkins Status:"
        kubectl get pods -n jenkins 2>/dev/null || echo "  Namespace not found or no pods"
        
        echo ""
        echo "SonarQube Status:"
        kubectl get pods -n sonarqube 2>/dev/null || echo "  Namespace not found or no pods"
        
        echo ""
        echo "Kyverno Status:"
        kubectl get pods -n kyverno 2>/dev/null || echo "  Namespace not found or no pods"
        
        echo ""
        echo "Persistent Volumes:"
        kubectl get pv 2>/dev/null | grep -E "(jenkins|sonarqube)" || echo "  No PVs found yet"
        
        echo ""
        echo "Persistent Volume Claims:"
        kubectl get pvc -A | grep -E "(jenkins|sonarqube)" || echo "  No PVCs found yet"
        echo ""
    done
}

# Create verification script
create_verification_script() {
    print_header "Creating Verification Script"
    
    cat > "$PROJECT_DIR/scripts/verify-argocd-setup.sh" << 'EOF'
#!/bin/bash

# ArgoCD Setup Verification Script

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

EAST_CLUSTER="east-cluster"
WEST_CLUSTER="west-cluster"

print_header() {
    echo -e "\n${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

verify_cluster() {
    local cluster_name=$1
    
    print_header "Verifying $cluster_name"
    
    kubectl config use-context $cluster_name
    
    # Check ArgoCD
    echo "ArgoCD Applications:"
    kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status 2>/dev/null || print_error "ArgoCD not accessible"
    
    # Check Jenkins
    echo -e "\nJenkins:"
    local jenkins_status=$(kubectl get pods -n jenkins -l app.kubernetes.io/component=jenkins-controller --no-headers 2>/dev/null | awk '{print $3}' | head -1)
    if [ "$jenkins_status" = "Running" ]; then
        print_success "Jenkins is running"
    else
        print_error "Jenkins status: ${jenkins_status:-Not deployed}"
    fi
    
    # Check SonarQube
    echo -e "\nSonarQube:"
    local sonarqube_status=$(kubectl get pods -n sonarqube -l app=sonarqube --no-headers 2>/dev/null | awk '{print $3}' | head -1)
    if [ "$sonarqube_status" = "Running" ]; then
        print_success "SonarQube is running"
    else
        print_error "SonarQube status: ${sonarqube_status:-Not deployed}"
    fi
    
    # Check Kyverno
    echo -e "\nKyverno:"
    local kyverno_status=$(kubectl get pods -n kyverno -l app.kubernetes.io/component=admission-controller --no-headers 2>/dev/null | awk '{print $3}' | head -1)
    if [ "$kyverno_status" = "Running" ]; then
        print_success "Kyverno is running"
        local policy_count=$(kubectl get cpol --no-headers 2>/dev/null | wc -l)
        print_info "Active policies: $policy_count"
    else
        print_error "Kyverno status: ${kyverno_status:-Not deployed}"
    fi
    
    # Check PVs
    echo -e "\nPersistent Volumes:"
    kubectl get pv | grep -E "(jenkins|sonarqube)" | while read line; do
        echo "  $line"
    done || echo "  No PVs found"
    
    # Check PVCs
    echo -e "\nPersistent Volume Claims:"
    kubectl get pvc -A | grep -E "(jenkins|sonarqube)" | while read line; do
        echo "  $line"
    done || echo "  No PVCs found"
    
    # Check Ingress
    echo -e "\nIngress Status:"
    kubectl get ingress -A 2>/dev/null | grep -E "(jenkins|sonarqube)" | while read line; do
        echo "  $line"
    done || echo "  No Ingress found"
}

# Test policy enforcement
test_policies() {
    print_header "Testing Kyverno Policies"
    
    kubectl config use-context $EAST_CLUSTER
    
    # Test privilege escalation policy
    echo "Testing privilege escalation policy (should fail):"
    if kubectl run test-privileged --image=nginx --privileged=true --dry-run=server 2>/dev/null; then
        print_error "Privilege escalation policy not enforced"
    else
        print_success "Privilege escalation policy working"
    fi
    
    # Test resource requirements
    echo -e "\nTesting resource requirements policy (should fail):"
    if kubectl run test-no-resources --image=nginx --dry-run=server 2>/dev/null; then
        print_error "Resource requirements policy not enforced"
    else
        print_success "Resource requirements policy working"
    fi
    
    # Clean up test pods
    kubectl delete pod test-privileged --ignore-not-found=true 2>/dev/null || true
    kubectl delete pod test-no-resources --ignore-not-found=true 2>/dev/null || true
}

main() {
    print_header "ArgoCD Setup Verification"
    
    verify_cluster $EAST_CLUSTER
    verify_cluster $WEST_CLUSTER
    test_policies
    
    print_header "Verification Complete"
    print_info "If all components show as running, your ArgoCD GitOps setup is working correctly!"
}

main "$@"
EOF

    chmod +x "$PROJECT_DIR/scripts/verify-argocd-setup.sh"
    print_success "Verification script created"
}

# Main function
main() {
    print_header "ArgoCD Setup and Deployment Automation"
    
    check_prerequisites
    create_directories
    
    # Install ArgoCD on both clusters
    install_argocd $EAST_CLUSTER
    install_argocd $WEST_CLUSTER
    
    create_argocd_service
    create_application_manifests
    
    # Deploy applications
    deploy_applications $EAST_CLUSTER
    deploy_applications $WEST_CLUSTER
    
    create_security_policies
    create_verification_script
    
    print_header "Deployment Complete"
    print_info "Waiting for services to be ready (this may take 5-10 minutes)..."
    sleep 60
    
    get_access_info
    monitor_deployments
    
    print_header "Setup Summary"
    print_success "ArgoCD installed on both clusters"
    print_success "Jenkins LTS deployed with GitOps"
    print_success "SonarQube deployed with PostgreSQL"
    print_success "Kyverno security policies active"
    print_info "Run './scripts/verify-argocd-setup.sh' to verify the setup"
    print_info "LoadBalancer URLs may take a few minutes to become available"
    print_info "Check pod logs and PVC status if applications are not running"
}

# Run main function
main "$@"
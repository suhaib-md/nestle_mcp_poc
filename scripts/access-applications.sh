#!/bin/bash

# Script to help access Jenkins and SonarQube through NGINX Ingress
# This script sets up port forwarding and provides access URLs

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

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Get LoadBalancer URLs
get_lb_urls() {
    local cluster_name=$1
    
    kubectl config use-context $cluster_name
    
    # Get NGINX Ingress LoadBalancer URL
    local nginx_hostname=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    # Get ArgoCD LoadBalancer URL
    local argocd_hostname=$(kubectl -n argocd get svc argocd-server-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    echo "Cluster: $cluster_name"
    if [ -n "$nginx_hostname" ]; then
        echo "  NGINX Ingress: http://$nginx_hostname"
        echo "  Jenkins: http://$nginx_hostname (Host: jenkins.local)"
        echo "  SonarQube: http://$nginx_hostname (Host: sonarqube.local)"
    else
        echo "  NGINX Ingress: LoadBalancer not ready"
    fi
    
    if [ -n "$argocd_hostname" ]; then
        echo "  ArgoCD: https://$argocd_hostname"
    else
        echo "  ArgoCD: LoadBalancer not ready"
    fi
    echo ""
}

# Setup local access using curl with Host headers
setup_local_access() {
    local cluster_name=$1
    
    kubectl config use-context $cluster_name
    
    local nginx_hostname=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -z "$nginx_hostname" ]; then
        print_error "NGINX LoadBalancer not ready on $cluster_name"
        return 1
    fi
    
    print_info "Creating access scripts for $cluster_name..."
    
    # Create Jenkins access script
    cat > "access-jenkins-${cluster_name}.sh" << EOF
#!/bin/bash
echo "Opening Jenkins on $cluster_name..."
echo "URL: http://$nginx_hostname"
echo "Use Host header: jenkins.local"
echo ""
echo "Login credentials:"
echo "Username: admin"
echo "Password: jenkins123!"
echo ""
echo "To access via browser, add this to your /etc/hosts file:"
echo "$nginx_hostname jenkins.local"
echo ""
echo "Or use curl:"
echo "curl -H 'Host: jenkins.local' http://$nginx_hostname"
xdg-open "http://$nginx_hostname" 2>/dev/null || open "http://$nginx_hostname" 2>/dev/null || echo "Please open http://$nginx_hostname manually with Host header: jenkins.local"
EOF
    chmod +x "access-jenkins-${cluster_name}.sh"
    
    # Create SonarQube access script
    cat > "access-sonarqube-${cluster_name}.sh" << EOF
#!/bin/bash
echo "Opening SonarQube on $cluster_name..."
echo "URL: http://$nginx_hostname"
echo "Use Host header: sonarqube.local"
echo ""
echo "Login credentials:"
echo "Username: admin"
echo "Password: admin123!"
echo ""
echo "To access via browser, add this to your /etc/hosts file:"
echo "$nginx_hostname sonarqube.local"
echo ""
echo "Or use curl:"
echo "curl -H 'Host: sonarqube.local' http://$nginx_hostname"
xdg-open "http://$nginx_hostname" 2>/dev/null || open "http://$nginx_hostname" 2>/dev/null || echo "Please open http://$nginx_hostname manually with Host header: sonarqube.local"
EOF
    chmod +x "access-sonarqube-${cluster_name}.sh"
    
    print_success "Access scripts created for $cluster_name"
}

# Setup /etc/hosts entries
setup_hosts_file() {
    print_header "Setting up /etc/hosts entries"
    
    print_warning "You may need to add entries to your /etc/hosts file for proper access"
    print_info "This requires sudo access to modify /etc/hosts"
    
    for cluster in $EAST_CLUSTER $WEST_CLUSTER; do
        kubectl config use-context $cluster
        local nginx_hostname=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        
        if [ -n "$nginx_hostname" ]; then
            echo ""
            echo "For $cluster, add these lines to /etc/hosts:"
            echo "$nginx_hostname jenkins.local"
            echo "$nginx_hostname sonarqube.local"
            
            # Offer to add automatically
            read -p "Add entries to /etc/hosts automatically for $cluster? (y/n): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                # Check if entries already exist
                if ! grep -q "jenkins.local" /etc/hosts; then
                    echo "$nginx_hostname jenkins.local" | sudo tee -a /etc/hosts >/dev/null
                    print_success "Added jenkins.local to /etc/hosts"
                else
                    print_info "jenkins.local already in /etc/hosts"
                fi
                
                if ! grep -q "sonarqube.local" /etc/hosts; then
                    echo "$nginx_hostname sonarqube.local" | sudo tee -a /etc/hosts >/dev/null
                    print_success "Added sonarqube.local to /etc/hosts"
                else
                    print_info "sonarqube.local already in /etc/hosts"
                fi
            fi
        fi
    done
}

# Test application access
test_access() {
    local cluster_name=$1
    
    print_header "Testing Application Access on $cluster_name"
    
    kubectl config use-context $cluster_name
    
    local nginx_hostname=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -z "$nginx_hostname" ]; then
        print_error "NGINX LoadBalancer not ready"
        return 1
    fi
    
    # Test Jenkins
    print_info "Testing Jenkins access..."
    local jenkins_response=$(curl -H "Host: jenkins.local" -s -o /dev/null -w "%{http_code}" "http://$nginx_hostname" --connect-timeout 10 || echo "000")
    if [ "$jenkins_response" -eq 200 ] || [ "$jenkins_response" -eq 302 ]; then
        print_success "Jenkins is accessible (HTTP $jenkins_response)"
    else
        print_error "Jenkins not accessible (HTTP $jenkins_response)"
    fi
    
    # Test SonarQube
    print_info "Testing SonarQube access..."
    local sonar_response=$(curl -H "Host: sonarqube.local" -s -o /dev/null -w "%{http_code}" "http://$nginx_hostname" --connect-timeout 10 || echo "000")
    if [ "$sonar_response" -eq 200 ] || [ "$sonar_response" -eq 302 ]; then
        print_success "SonarQube is accessible (HTTP $sonar_response)"
    else
        print_error "SonarQube not accessible (HTTP $sonar_response)"
    fi
}

# Get application passwords
get_passwords() {
    print_header "Application Credentials"
    
    for cluster in $EAST_CLUSTER $WEST_CLUSTER; do
        echo -e "\n${YELLOW}=== $cluster ===${NC}"
        kubectl config use-context $cluster
        
        # ArgoCD password
        local argocd_password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "Not available")
        
        echo "ArgoCD:"
        echo "  Username: admin"
        echo "  Password: $argocd_password"
        echo ""
        echo "Jenkins:"
        echo "  Username: admin"
        echo "  Password: jenkins123!"
        echo ""
        echo "SonarQube:"
        echo "  Username: admin"
        echo "  Password: admin123!"
        echo ""
    done
}

# Create port-forward scripts for local development
create_port_forward_scripts() {
    print_header "Creating Port-Forward Scripts"
    
    for cluster in $EAST_CLUSTER $WEST_CLUSTER; do
        # Jenkins port-forward script
        cat > "jenkins-port-forward-${cluster}.sh" << EOF
#!/bin/bash
echo "Setting up port forwarding for Jenkins on $cluster..."
echo "Jenkins will be available at: http://localhost:8080"
echo "Press Ctrl+C to stop"
kubectl config use-context $cluster
kubectl port-forward -n jenkins svc/jenkins 8080:8080
EOF
        chmod +x "jenkins-port-forward-${cluster}.sh"
        
        # SonarQube port-forward script
        cat > "sonarqube-port-forward-${cluster}.sh" << EOF
#!/bin/bash
echo "Setting up port forwarding for SonarQube on $cluster..."
echo "SonarQube will be available at: http://localhost:9000"
echo "Press Ctrl+C to stop"
kubectl config use-context $cluster
kubectl port-forward -n sonarqube svc/sonarqube-sonarqube 9000:9000
EOF
        chmod +x "sonarqube-port-forward-${cluster}.sh"
        
        # ArgoCD port-forward script
        cat > "argocd-port-forward-${cluster}.sh" << EOF
#!/bin/bash
echo "Setting up port forwarding for ArgoCD on $cluster..."
echo "ArgoCD will be available at: https://localhost:8443"
echo "Press Ctrl+C to stop"
kubectl config use-context $cluster
kubectl port-forward -n argocd svc/argocd-server 8443:443
EOF
        chmod +x "argocd-port-forward-${cluster}.sh"
    done
    
    print_success "Port-forward scripts created"
    print_info "Use these scripts if you prefer local port forwarding over LoadBalancer access"
}

# Main menu
show_menu() {
    echo ""
    echo "Application Access Helper"
    echo "========================"
    echo "1. Show LoadBalancer URLs"
    echo "2. Setup /etc/hosts entries"
    echo "3. Test application access"
    echo "4. Show credentials"
    echo "5. Create access scripts"
    echo "6. Create port-forward scripts"
    echo "7. All of the above"
    echo "8. Exit"
    echo ""
    read -p "Select an option (1-8): " choice
    
    case $choice in
        1)
            print_header "LoadBalancer URLs"
            get_lb_urls $EAST_CLUSTER
            get_lb_urls $WEST_CLUSTER
            show_menu
            ;;
        2)
            setup_hosts_file
            show_menu
            ;;
        3)
            test_access $EAST_CLUSTER
            test_access $WEST_CLUSTER
            show_menu
            ;;
        4)
            get_passwords
            show_menu
            ;;
        5)
            setup_local_access $EAST_CLUSTER
            setup_local_access $WEST_CLUSTER
            show_menu
            ;;
        6)
            create_port_forward_scripts
            show_menu
            ;;
        7)
            get_lb_urls $EAST_CLUSTER
            get_lb_urls $WEST_CLUSTER
            setup_hosts_file
            test_access $EAST_CLUSTER
            test_access $WEST_CLUSTER
            get_passwords
            setup_local_access $EAST_CLUSTER
            setup_local_access $WEST_CLUSTER
            create_port_forward_scripts
            print_success "All setup complete!"
            ;;
        8)
            print_info "Goodbye!"
            exit 0
            ;;
        *)
            print_error "Invalid option"
            show_menu
            ;;
    esac
}

# Quick access function
quick_access() {
    if [ "$1" = "--quick" ]; then
        print_header "Quick Access Setup"
        get_lb_urls $EAST_CLUSTER
        get_lb_urls $WEST_CLUSTER
        get_passwords
        exit 0
    fi
}

# Usage information
usage() {
    echo "Usage: $0 [--quick]"
    echo ""
    echo "Options:"
    echo "  --quick    Show URLs and credentials only"
    echo "  (no args) Interactive menu"
    echo ""
    exit 1
}

# Main execution
main() {
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        usage
    fi
    
    quick_access "$1"
    
    print_header "Application Access Helper"
    print_info "This script helps you access Jenkins, SonarQube, and ArgoCD"
    print_info "Make sure your applications are deployed and running first"
    
    show_menu
}

main "$@"

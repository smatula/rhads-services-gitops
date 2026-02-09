#!/bin/bash
set -euo pipefail

# Get cluster ingress domain
INGRESS_DOMAIN=$(oc -n openshift-ingress-operator get ingresscontrollers.operator.openshift.io default -o jsonpath='{.status.domain}' 2>/dev/null || echo "apps.example.com")

# Create Argo manager cluster SA
kubectl create serviceaccount cluster-argocd-manager -n kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding cluster-argocd-manager-binding --clusterrole=admin --serviceaccount=kube-system:cluster-argocd-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f components/register-cluster/cluster_sa_token.yaml

# Set Server variables
SERVER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
export SERVER_URL
CA_DATA=$(kubectl get cm kube-root-ca.crt -o jsonpath="{['data']['ca\\.crt']}" | base64 -w 0)
export CA_DATA
BTOKEN=$(kubectl get secret cluster-argocd-manager-token -n kube-system -o jsonpath="{.data.token}" | base64 --decode)
export BTOKEN

# Set TPA variables
TPA_NAMESPACE="tssc-tpa"
REALM="chicken"

# Set TAS variables
TAS_REALM="trusted-artifact-signer"

# Derive annotation values
export APP_DOMAIN_URL="-${TPA_NAMESPACE}.${INGRESS_DOMAIN}"
export KEYCLOAK_HOST="sso.${INGRESS_DOMAIN}"
export OIDC_ISSUER_URL="https://sso.${INGRESS_DOMAIN}/realms/${REALM}"
export REDIRECT_URI1="https://server${APP_DOMAIN_URL}"
export REDIRECT_URI2="https://server${APP_DOMAIN_URL}/*"
export REDIRECT_URI3="https://sbom${APP_DOMAIN_URL}"
export REDIRECT_URI4="https://sbom${APP_DOMAIN_URL}/*"
export TAS_EMAIL="trusted-artifact-signer@${INGRESS_DOMAIN}"
export TAS_ISSUER_URL="https://${KEYCLOAK_HOST}/realms/${TAS_REALM}"

# Add Cluster secret to register
envsubst < components/register-cluster/cluster_secret.yaml | kubectl apply -f -

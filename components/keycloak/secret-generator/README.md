# TPA Secret Generator

This directory contains ArgoCD hooks to generate secrets and ConfigMaps for the TPA (Trusted Profile Analyzer) deployment.

## Overview

This replaces the old `create_secrets.sh` script with a declarative, GitOps-friendly approach. Secrets and ConfigMaps are generated dynamically based on the cluster's ingress domain.

## How It Works

When ArgoCD syncs the TPA application:

1. **Wave 0**: RBAC resources created (ServiceAccount, Roles, RoleBindings)
2. **Wave 1 - Sync Hook Runs**: The Job in argocd-hook.yaml executes
3. **Queries Cluster**: Gets the ingress domain from the IngressController
4. **Generates Secrets**: Creates all secrets with random passwords (or reuses existing ones)
5. **Creates ConfigMap**: Generates environment-specific values
6. **Wave 2+**: Rest of application deploys

**Just commit and push** - ArgoCD handles everything automatically!

## Key Features

✅ **Fully automated** - No manual steps with ArgoCD
✅ **Environment-aware** - Auto-derives URLs from cluster ingress
✅ **Password preservation** - Reuses existing secrets across syncs
✅ **No secrets in git** - Everything generated at deployment time
✅ **Idempotent** - Safe to run multiple times

## Generated Resources

### Secrets (7 total):
1. `tpa-pgsql-user` - TPA database credentials
2. `keycloak-pgsql-user` - Keycloak database credentials
3. `tpa-realm-chicken-admin` (both namespaces) - Realm admin credentials
4. `tpa-realm-chicken-clients` (both namespaces) - OIDC client secrets
5. `tssc-trustification-integration` - Trustification config

### ConfigMap:
- `tpa-values-source` - Environment-specific URLs and domains

## Migration from create_secrets.sh

### Before:
```bash
source ./envfile
./create_secrets.sh  # Creates secrets via oc apply
yq -i '...' kustomization.yaml  # Manual edits
git commit  # Commit modified kustomization.yaml
```

### After:
```bash
git commit  # Just commit your changes
git push    # ArgoCD Sync hook generates everything automatically
```

## Troubleshooting

### Check hook Job logs:
```bash
oc logs -n tssc-tpa job/tpa-generate-secrets
```

### Regenerate with new domain:
```bash
oc delete cm tpa-values-source -n tssc-tpa
# Trigger ArgoCD sync or re-run generate-secrets.sh
```

## Security

- ✅ No secrets stored in git
- ✅ Passwords generated in-cluster only
- ✅ Preserved across syncs (idempotent)
- ✅ RBAC-controlled generation

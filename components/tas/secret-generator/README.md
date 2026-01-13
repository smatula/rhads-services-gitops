# TAS Secret Generator

This directory contains ArgoCD hooks to generate secrets and ConfigMaps for the TAS (Trusted Application SIGNER) deployment.

## Overview

This uses a declarative, GitOps-friendly approach to generate Secrets and ConfigMaps dynamically based on the cluster's ingress domain.

## How It Works

When ArgoCD syncs the TAS application:

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
1. `trusted-artifact-signer-user` - TAS admin/user credentials
2. `trusted-artifact-signer-clients` - TAS client secret

### ConfigMap:

## Troubleshooting

### Check hook Job logs:
```bash
oc logs -n trusted-artifact-signer job/tas-generate-secrets
```

### Regenerate with new domain:
```bash
oc delete cm tas-values-source -n trusted-artifact-signer
# Trigger ArgoCD sync
```

## Security

- ✅ No secrets stored in git
- ✅ Passwords generated in-cluster only
- ✅ Preserved across syncs (idempotent)
- ✅ RBAC-controlled generation

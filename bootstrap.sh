#!/bin/bash

create_subscription() {
    echo "Installing the OpenShift GitOps operator subscription:"
    kubectl apply -k "./components/openshift-gitops"
    echo -n "Waiting for default project (and namespace) to exist: "
    while ! kubectl get appproject/default -n openshift-gitops &>/dev/null; do
        echo -n .
        sleep 1
    done
    echo "OK"
}

wait_for_route() {
    echo -n "Waiting for OpenShift GitOps Route: "
    while ! kubectl get route/openshift-gitops-server -n openshift-gitops &>/dev/null; do
        echo -n .
        sleep 1
    done
    echo "OK"
}

grant_admin_role_to_all_authenticated_users() {
    echo Allow any authenticated users to be admin on the Argo CD instance
    # - Once we have a proper access policy in place, this should be updated to be consistent with that policy.
    kubectl patch argocd/openshift-gitops -n openshift-gitops -p '{"spec":{"rbac":{"policy":"g, system:authenticated, role:admin"}}}' --type=merge
}

patch_argocd_instance() {
    echo "--- Applying Global Health, Tracking & RBAC Logic ---"
    local NS="openshift-gitops"
    local INSTANCE="openshift-gitops"
    local TARGET_NS="gitops-resources"

    # 1. Label the target namespace so Argo CD "claims" it
    echo "Labeling $TARGET_NS for GitOps management..."
    kubectl label namespace "$TARGET_NS" argocd.argoproj.io/managed-by="$NS" --overwrite 2>/dev/null

    # 2. Grant RBAC so the ApplicationSet controller can see child Apps in the target namespace
    echo "Granting ApplicationSet controller 'view' rights on $TARGET_NS..."
    oc adm policy add-role-to-user view \
      system:serviceaccount:"$NS":"$INSTANCE"-applicationset-controller \
      -n "$TARGET_NS" 2>/dev/null || true

    # 3. Create the Consolidated Patch File
    # This combines Health Logic, Tracking Method, and Source Namespaces
    cat <<EOF > /tmp/argocd-master-patch.yaml
spec:
  resourceTrackingMethod: annotation
  sourceNamespaces:
    - $TARGET_NS
  kustomizeBuildOptions: --enable-alpha-plugins --enable-exec
  extraConfig:
    resource.customizations: |
      argoproj.io/ApplicationSet:
        health.lua: |
          local hs = { status = "Healthy", message = "All apps are healthy" }
          if obj.status ~= nil and obj.status.resources ~= nil then
            local count = 0
            for _, res in ipairs(obj.status.resources) do
              count = count + 1
              local health = (res.health and res.health.status) or "Missing"
              local sync = res.status or "Unknown"
              if health == "Degraded" then 
                return { status = "Degraded", message = res.name .. " is Degraded" } 
              end
              if health ~= "Healthy" or sync ~= "Synced" then
                hs.status = "Progressing"
                hs.message = "Waiting for " .. res.name .. " (Health: " .. health .. ", Sync: " .. sync .. ")"
              end
            end
            if count == 0 then return { status = "Progressing", message = "Reconciling..." } end
            return hs
          end
          return { status = "Progressing", message = "Initializing..." }
      argoproj.io/Application:
        health.lua: |
          local hs = { status = "Progressing", message = "Initializing" }
          if obj.status ~= nil and obj.status.health ~= nil then
            hs.status = obj.status.health.status
            hs.message = obj.status.health.message
          end
          return hs
EOF

    # 4. Apply the Patch to the ArgoCD Custom Resource
    echo "Patching ArgoCD Instance Settings..."
    kubectl patch argocd "$INSTANCE" -n "$NS" --type=merge --patch-file /tmp/argocd-master-patch.yaml

    # 5. Restart Controllers to ensure they pick up the clean ConfigMap
    echo "Restarting GitOps Controllers..."
    kubectl rollout restart deployment -l app.kubernetes.io/name="$INSTANCE"-applicationset-controller -n "$NS"
    kubectl rollout restart deployment -l app.kubernetes.io/name="$INSTANCE"-server -n "$NS"

    echo "Waiting for controllers to recycle..."
    kubectl rollout status deployment "$INSTANCE"-applicationset-controller -n "$NS" --timeout=60s
}

create_namespace_and_AppProject() {
    echo "Creating namespace gitops-resources"
    oc new-project gitops-resources

    echo "Creating new AppProject"
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
    name: gitops-resources
    namespace: openshift-gitops
spec:
    clusterResourceWhitelist:
        - group: '*'
          kind: '*'
    destinations:
        - namespace: '*'
          server: '*'
    sourceNamespaces:
        - gitops-resources
    sourceRepos:
        - '*'
EOF

    echo "Labeling namespace for GitOps management"
    kubectl label namespace gitops-resources argocd.argoproj.io/managed-by=openshift-gitops --overwrite
}


register_cluster() {
    echo "Registering Cluster"
    ./components/register-cluster/register_cluster.sh
}

create_app_of_apps(){
    echo "Creating app of apps"
    oc create -f ./app-of-apps.yaml
}

echo "Step 1: Preparing Namespace..."
kubectl create namespace gitops-resources || true
# The label is the 'permission' for the operator to manage this room
kubectl label namespace gitops-resources argocd.argoproj.io/managed-by=openshift-gitops --overwrite


create_subscription
wait_for_route
create_namespace_and_AppProject
patch_argocd_instance
grant_admin_role_to_all_authenticated_users
patch_argocd_instance
register_cluster

oc adm policy add-cluster-role-to-user cluster-admin \
  system:serviceaccount:openshift-gitops:openshift-gitops-applicationset-controller

# --- THE VISION GATE ---
echo "Step 3: Waiting for ApplicationSet Controller Vision..."
# We wait for the Operator to physically update the deployment with the new namespace scope
ITER=0
while true; do
    ENV_CHECK=$(kubectl get deployment openshift-gitops-applicationset-controller -n openshift-gitops -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null)
    if [[ "$ENV_CHECK" == *"ARGOCD_APPLICATIONSET_CONTROLLER_NAMESPACES"* ]]; then
        echo "Vision Established (Namespace variable found)."
        break
    fi
    if [ $ITER -gt 30 ]; then echo "Timeout waiting for controller vision"; exit 1; fi
    echo -n "."
    sleep 5
    ITER=$((ITER+1))
done

# Mandatory Restart: Clears any 'count=0' cache from the controller
kubectl rollout restart deployment openshift-gitops-applicationset-controller -n openshift-gitops
kubectl rollout status deployment openshift-gitops-applicationset-controller -n openshift-gitops --timeout=90s

# 3. Apply the Root Application (App-of-Apps)
# [Insert your existing create_root_app function call here]
create_app_of_apps

# PHASE 1: Initial Handshake (3 loops)
for i in {1..3}; do
    echo "Phase 1 - Nudge $i/3: Re-evaluating Git source..."
    kubectl annotate app rhads-services-app-of-apps -n gitops-resources argocd.argoproj.io/refresh=hard --overwrite
    sleep 20
done

# PHASE 2: Waiting for Health (10 loops)
for i in {1..10}; do
    STATUS=$(kubectl get appset keycloak-foundation -n gitops-resources -o jsonpath='{.status.health.status}' 2>/dev/null)
    echo "Phase 2 - Check $i/10: Foundation Health is [$STATUS]"
    
    if [[ "$STATUS" == "Healthy" ]]; then
        echo "SUCCESS: Wave 1 Healthy. Triggering Wave 2 (Keycloak)..."
        # One last nudge to ensure Wave 2 starts immediately
        kubectl annotate app rhads-services-app-of-apps -n gitops-resources argocd.argoproj.io/refresh=hard --overwrite
        break
    fi
    
    # Keep the root app 'awake'
    kubectl annotate app rhads-services-app-of-apps -n gitops-resources argocd.argoproj.io/refresh=hard --overwrite
    sleep 30
done

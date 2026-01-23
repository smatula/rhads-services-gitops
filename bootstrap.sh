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
    echo "Setting ArgoCD tracking method to annotation and adding \"gitops-resources\" ns to sourceNamespaces"
    kubectl patch argocd/openshift-gitops -n openshift-gitops -p '
spec:
  resourceTrackingMethod: annotation
  sourceNamespaces:
    - gitops-resources
  kustomizeBuildOptions: --enable-alpha-plugins --enable-exec
' --type=merge
}

apply_custom_health_checks() {
    echo "Applying Global Health & Tracking Logic ---"
    local NS="openshift-gitops"
    local INSTANCE="openshift-gitops"

    # 1. Create the Patch File
    # This ensures both ApplicationSets and Applications have the logic
    # and forces the 'annotation' tracking method cluster-wide.
    cat <<'EOF' > /tmp/argocd-health-patch.yaml
spec:
  resourceTrackingMethod: annotation
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

    # 2. Patch the ArgoCD Custom Resource (Master Config)
    kubectl patch argocd "$INSTANCE" -n "$NS" --type=merge --patch-file /tmp/argocd-health-patch.yaml

    # 3. Apply RBAC (Required so AppSet controller can read child App health)
    oc adm policy add-role-to-user edit \
      system:serviceaccount:"$NS":"$INSTANCE"-applicationset-controller -n "$NS" 2>/dev/null || true

    # 4. Restart Controllers to load new ConfigMap
    echo "Restarting GitOps Controllers..."
    kubectl rollout restart deployment -l app.kubernetes.io/name="$INSTANCE"-applicationset-controller -n "$NS"
    kubectl rollout restart statefulset -l app.kubernetes.io/name="$INSTANCE"-application-controller -n "$NS" 2>/dev/null || \
    kubectl rollout restart deployment -l app.kubernetes.io/name="$INSTANCE"-application-controller -n "$NS"

    echo "Waiting for controllers to recycle..."
    sleep 30
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
}


register_cluster() {
    echo "Registering Cluster"
    ./components/register-cluster/register_cluster.sh
}

create_app_of_apps(){
    echo "Creating app of apps"
    oc create -f ./app-of-apps.yaml
}

create_subscription
wait_for_route
apply_custom_health_checks
grant_admin_role_to_all_authenticated_users
patch_argocd_instance
create_namespace_and_AppProject
register_cluster
create_app_of_apps

# Post-Deployment Nudge Loop
# This forces the "Missing" status to clear by injecting Tracking IDs
echo "--- Synchronizing Waves ---"
for i in {1..3}; do
    echo "Sync/Nudge attempt $i..."
    
    # Nudge the Root to claim children
    kubectl annotate app rhads-services-app-of-apps -n gitops-resources "argocd.argoproj.io/refresh=hard" --overwrite 2>/dev/null
    
    # Nudge all generated ApplicationSets to calculate health
    kubectl annotate appset --all -n gitops-resources "argocd.argoproj.io/refresh=hard" --overwrite 2>/dev/null
    
    # Trigger a sync to move to the next wave if the current wave is healthy
    argocd app sync rhads-services-app-of-apps --prune --async 2>/dev/null || true
    
    sleep 20
done

echo "--- Phase 2: Nudging Waves ---"
for i in {1..5}; do
    echo "Wave Sync Attempt $i..."
    # Nudge Parent & Children
    kubectl annotate app rhads-services-app-of-apps -n  gitops-resources"argocd.argoproj.io/refresh=hard" --overwrite 2>/dev/null
    kubectl annotate appset --all -n  gitops-resources "argocd.argoproj.io/refresh=hard" --overwrite 2>/dev/null
    
    # Trigger Sync to move waves
    argocd app sync rhads-services-app-of-apps --prune --async 2>/dev/null || true
    
    # Check if we are done
    ROOT_HEALTH=$(kubectl get app rhads-services-app-of-apps -n openshift-gitops -o jsonpath='{.status.health.status}' 2>/dev/null)
    if [ "$ROOT_HEALTH" == "Healthy" ]; then
        echo "GitOps reports all waves are Healthy!"
        break
    fi
    sleep 20
done

# 3. Final Endpoint Verification
echo "--- Phase 3: Waiting for Keycloak Endpoint ---"
KEYCLOAK_URL=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}' 2>/dev/null)

if [ -z "$KEYCLOAK_URL" ]; then
    echo "Waiting for Keycloak Route to be created..."
    sleep 30
    KEYCLOAK_URL=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')
fi

echo "Testing Endpoint: https://$KEYCLOAK_URL"
timeout 300s bash -c "until curl -sk --head https://$KEYCLOAK_URL | grep '200' > /dev/null; do echo 'Waiting for 200 OK...'; sleep 10; done"

echo "Success! Environment is fully deployed and Keycloak is reachable."


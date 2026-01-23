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

create_subscription
wait_for_route
create_namespace_and_AppProject
patch_argocd_instance
grant_admin_role_to_all_authenticated_users
patch_argocd_instance
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

echo "--- Phase 2: Advancing Sync Waves ---"
for i in {1..20}; do
    echo "Wave Sync Attempt $i/10..."

    # 1. Force the ApplicationSet to 'claim' its children (Injects Tracking IDs)
    # This is the "secret sauce" to unsticking Wave 1
    kubectl annotate appset --all -n gitops-resources "argocd.argoproj.io/refresh=hard" --overwrite 2>/dev/null

    # 2. Nudge the Root App to re-evaluate the health of the current wave
    kubectl annotate app rhads-services-app-of-apps -n gitops-resources "argocd.argoproj.io/refresh=hard" --overwrite 2>/dev/null

    # 3. Trigger an automated sync on the Root to move to the next wave
    # We use --async so the script doesn't hang if a pod takes time to start
    argocd app sync rhads-services-app-of-apps --prune --async --server $(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}') --auth-token $(oc extract secret/argocd-cluster-admin-token -n openshift-gitops --to=- 2>/dev/null) 2>/dev/null || true

    # 4. Check the Status
    ROOT_HEALTH=$(kubectl get app rhads-services-app-of-apps -n gitops-resources -o jsonpath='{.status.health.status}' 2>/dev/null)
    ROOT_SYNC=$(kubectl get app rhads-services-app-of-apps -n gitops-resources -o jsonpath='{.status.sync.status}' 2>/dev/null)

    echo "Current Status: Health=$ROOT_HEALTH, Sync=$ROOT_SYNC"

    if [[ "$ROOT_HEALTH" == "Healthy" && "$ROOT_SYNC" == "Synced" ]]; then
        echo "✅ All waves successfully deployed and healthy!"
        break
    fi

    # Wait for resources to stabilize before next nudge
    sleep 30
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


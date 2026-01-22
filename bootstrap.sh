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
    echo "Applying Final Production Fix (Health + Sync + Tracking)..."
    local NS="openshift-gitops"
    local INSTANCE="openshift-gitops"

    # 1. Update ArgoCD CR
    # - Sets tracking to 'annotation' (Fixes the empty grep/Ghost issue)
    # - Includes the Lua script for AppSets (Health + Sync check)
    cat <<EOF > /tmp/health-patch.yaml
spec:
  resourceTrackingMethod: annotation
  extraConfig:
    resource.customizations: |
      argoproj.io/ApplicationSet:
        health.lua: |
          local hs = { status = "Healthy", message = "All apps are healthy and synced" }
          if obj.status ~= nil and obj.status.resources ~= nil then
            for _, res in ipairs(obj.status.resources) do
              local health = (res.health and res.health.status) or "Missing"
              local sync = res.status or "Unknown"
              
              if health == "Degraded" then
                return { status = "Degraded", message = res.name .. " is Degraded" }
              end
              
              -- The Sync check: AppSet is Progressing until children are Healthy AND Synced
              if health ~= "Healthy" or sync ~= "Synced" then
                hs.status = "Progressing"
                hs.message = "Waiting for " .. res.name .. " (Health: " .. health .. ", Sync: " .. sync .. ")"
              end
            end
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

    kubectl patch argocd/"$INSTANCE" -n "$NS" --type=merge --patch-file /tmp/health-patch.yaml

    # 2. RBAC: Ensure ApplicationSet controller can manage apps
    oc adm policy add-role-to-user edit \
      system:serviceaccount:"$NS":"$INSTANCE"-applicationset-controller -n "$NS" 2>/dev/null || true

    # 3. Restart Controllers to adopt the new tracking method
    echo "Restarting controllers..."
    kubectl rollout restart deployment/"$INSTANCE"-applicationset-controller -n "$NS"
    kubectl rollout restart deployment/"$INSTANCE"-application-controller -n "$NS"
    kubectl rollout status deployment/"$INSTANCE"-applicationset-controller -n "$NS" --timeout=60s

    # 4. CRITICAL: Force the App-of-Apps to inject the tracking-ids
    # This turns the "Ghosts" back into real resources.
    echo "Triggering hard refresh and sync on root App-of-Apps..."
    sleep 10
    # This command forces the parent to re-examine children and apply the new tracking annotations
    kubectl annotate app rhads-services-app-of-apps -n "$NS" "argocd.argoproj.io/refresh=hard" --overwrite
    
    rm -f /tmp/health-patch.yaml
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

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

Here is the updated function for your bash script.

I have modified the Lua logic to target the status.resources field (which your cluster is using) instead of the standard applicationStatus field. I also added a check for the Missing status you observed, ensuring the ApplicationSet stays in a Progressing state until the child app is actually created and synced.

Updated Bash Function
Bash
apply_custom_health_checks() {
    echo "Applying custom health checks via extraConfig..."
    local NS="openshift-gitops"
    local INSTANCE="openshift-gitops"

    # Using extraConfig to map directly to argocd-cm Data
    cat <<EOF > /tmp/health-patch.yaml
spec:
  extraConfig:
    resource.customizations: |
      argoproj.io/ApplicationSet:
        health.lua: |
          local hs = { status = "Healthy", message = "All apps are healthy" }
          -- Logic specifically for 'status.resources' as seen in your cluster
          if obj.status ~= nil and obj.status.resources ~= nil then
            local count = 0
            for _, res in ipairs(obj.status.resources) do
              count = count + 1
              local health = "Unknown"
              if res.health ~= nil and res.health.status ~= nil then
                health = res.health.status
              end

              -- Priority 1: Degraded
              if health == "Degraded" then
                return { status = "Degraded", message = "Child app " .. res.name .. " is Degraded" }
              end
              
              -- Priority 2: Progressing/Syncing
              if health == "Progressing" or health == "Missing" or health == "Unknown" or res.status == "OutOfSync" then
                hs.status = "Progressing"
                hs.message = "Child app " .. res.name .. " is " .. health .. " / " .. (res.status or "Syncing")
              end
            end
            if count == 0 then
              return { status = "Progressing", message = "No resources generated yet" }
            end
            return hs
          end
          return { status = "Progressing", message = "Waiting for status.resources..." }
      
      argoproj.io/Application:
        health.lua: |
          local hs = { status = "Progressing", message = "Initializing" }
          if obj.status ~= nil and obj.status.health ~= nil then
            hs.status = obj.status.health.status
            hs.message = obj.status.health.message
          end
          return hs
EOF

    echo "Patching ArgoCD instance..."
    kubectl patch argocd/"$INSTANCE" -n "$NS" --type=merge --patch-file /tmp/health-patch.yaml

    echo -n "Waiting for ConfigMap to sync: "
    for i in {1..15}; do
        if kubectl get cm argocd-cm -n "$NS" -o jsonpath='{.data.resource\.customizations}' | grep -q "resources"; then
            echo "OK"
            break
        fi
        echo -n "."
        sleep 2
    done

    echo "Restarting controllers to apply new Lua logic..."
    kubectl rollout restart deployment/openshift-gitops-applicationset-controller -n "$NS"
    
    # Wait for the main controller to exist before attempting restart
    if kubectl get deployment/openshift-gitops-application-controller -n "$NS" &>/dev/null; then
        kubectl rollout restart deployment/openshift-gitops-application-controller -n "$NS"
    else
        echo "Main controller not found yet; it will load the config on startup."
    fi
    
    rm -f /tmp/health-patch.yaml
}

#    echo "Setting ArgoCD Health Check"
#    kubectl patch argocd/openshift-gitops -n openshift-gitops --type=merge -p '
#spec:
#  resourceHealthChecks:
#    - group: argoproj.io
#      kind: Application
#      check: |
#        hs = {}
#        hs.status = "Progressing"
#        hs.message = ""
#        if obj.status ~= nil then
#          if obj.status.health ~= nil then
#            hs.status = obj.status.health.status
#            if obj.status.health.message ~= nil then
#              hs.message = obj.status.health.message
#            end
#          end
#        end
#        return hs
#    - group: argoproj.io
#      kind: ApplicationSet
#      check: |
#        local hs = {}
#        hs.status = "Healthy"
#        hs.message = ""
#        if obj.status ~= nil and obj.status.applicationStatus ~= nil then
#          for _, app in ipairs(obj.status.applicationStatus) do
#            if app.status ~= "Healthy" then
#              hs.status = "Progressing"
#              hs.message = "Waiting for child application: " .. app.application
#              return hs
#            end
#          end
#        end
#        return hs
#'
#}

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

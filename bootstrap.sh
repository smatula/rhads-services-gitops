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
    echo "Applying custom health checks for ApplicationSet and Application"
    
    # Define the Lua scripts in a variable to keep the patch command clean
    local CUSTOM_HEALTH="
argoproj.io/ApplicationSet:
  health.lua: |
    local hs = { status = 'Healthy', message = 'All apps are healthy and synced' }
    if obj.status ~= nil and obj.status.applicationStatus ~= nil then
      for _, app in ipairs(obj.status.applicationStatus) do
        if app.status == 'Degraded' then
          return { status = 'Degraded', message = 'Child app ' .. app.application .. ' is Degraded' }
        end
        if app.status == 'Progressing' or app.status == 'Unknown' or app.status == 'Waiting' or app.syncStatus == 'OutOfSync' then
          hs.status = 'Progressing'
          hs.message = 'Child app ' .. app.application .. ' is ' .. (app.status or 'Syncing')
        end
      end
      return hs
    end
    return { status = 'Progressing', message = 'Waiting for reconciliation...' }

    argoproj.io/Application:
      health.lua: |
        local hs = { status = 'Progressing', message = 'Initializing' }
        if obj.status ~= nil and obj.status.health ~= nil then
          hs.status = obj.status.health.status
          hs.message = obj.status.health.message
        end
        return hs
"

    # Apply the patch to the ArgoCD Custom Resource
    kubectl patch argocd/openshift-gitops -n openshift-gitops --type=merge -p "$(char_count=1; printf '{"spec":{"resourceCustomizations":%q}}' "$CUSTOM_HEALTH")"

    echo "Restarting application-controller to load new health scripts..."
    kubectl rollout restart deployment/openshift-gitops-application-controller -n openshift-gitops
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

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
grant_admin_role_to_all_authenticated_users
patch_argocd_instance
create_namespace_and_AppProject
register_cluster
create_app_of_apps

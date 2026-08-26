helm upgrade --install kyverno kyverno/kyverno -n kyverno -f values.yaml

# values.yaml

backgroundController:
  rbac:
    clusterRole:
      extraResources:
        - apiGroups: [""]
          resources: ["persistentvolumeclaims"]
          verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

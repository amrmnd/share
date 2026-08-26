helm upgrade --install kyverno kyverno/kyverno -n kyverno \
  --set 'backgroundController.rbac.clusterRole.extraResources[0].apiGroups={""}' \
  --set 'backgroundController.rbac.clusterRole.extraResources[0].resources={persistentvolumeclaims}' \
  --set 'backgroundController.rbac.clusterRole.extraResources[0].verbs={get\,list\,watch\,create\,update\,patch\,delete}'

#!/bin/bash

clear

# helm install vault openbao/openbao -n vault --set 'server.dev.enabled=true' --set 'ui.enabled=true' --create-namespace --set 'fullnameOverride=vault'

. ../demo-magic.sh
# . ~/.bashrc
pe "# Creation d'un ns pour l'ESO"
pe "kubectl create ns external-secrets"
pei "kubens external-secrets"

echo ""

pe "# Création du service account"
pe "kubectl create sa operator-auth -n external-secrets"

echo ""
pe "# Création d'un token pour le SA"
p "kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: operator-auth
  annotations:
    kubernetes.io/service-account.name: operator-auth
type: kubernetes.io/service-account-token
EOF"

kubectl apply -f manifests/secretsa.yaml

echo ""

pe "# Création du clusterrolebinding pour le service account operator-auth"
pe "kubectl create clusterrolebinding role-tokenreview-binding \
--clusterrole=system:auth-delegator \
--serviceaccount=external-secrets:operator-auth"

echo ""

pe "# Récupération du token, du ca cert et du host"
p "TOKEN_REVIEW_JWT=\$(kubectl get secret operator-auth -n external-secrets --output='go-template={{ .data.token }}' | base64 --decode)"
export TOKEN_REVIEW_JWT=$(kubectl get secret operator-auth -n external-secrets --output='go-template={{ .data.token }}' | base64 --decode)
p "KUBE_CA_CERT=\$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.certificate-authority-data}' | base64 --decode)"
export KUBE_CA_CERT=$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.certificate-authority-data}' | base64 --decode)
p "KUBE_HOST=\$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.server}')"
export KUBE_HOST=$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.server}')

echo ""

# pe "# Déploiement d'OpenBao"
# pei "helm repo add openbao https://openbao.github.io/openbao-helm"
# pei "helm repo update"
# pe "helm install openbao openbao/openbao -n bao --set 'server.dev.enabled=true' --create-namespace"

# echo ""

pe "# On expose le port 8200"
# pei "kubens bao"
pe "kubectl port-forward -n vault pod/vault-0 8200 2>&1 > /dev/null &"

echo ""
# pei "# Pour le fun"
# p "alias vault='bao'"
pe "vault --version"

pe "# On exporte nos variables VAULT_ADDR et VAULT_TOKEN"
pe "export VAULT_ADDR=http://localhost:8200"
pe "export VAULT_TOKEN='root'"

echo ""

pei "### Dans Vault ###"
pe "# On créé le Secret Engine"
pe "vault secrets enable -path=kvv2 kv-v2"

echo ""

pe "# On créé l'authent Kube"
pe "vault auth enable -path external-secrets-operator kubernetes"

echo ""

pe "# On configure l'authent Kube"
p "vault write auth/external-secrets-operator/config token_reviewer_jwt='\$TOKEN_REVIEW_JWT' kubernetes_host='\$KUBE_HOST' kubernetes_ca_cert='\$KUBE_CA_CERT'" 

vault write auth/external-secrets-operator/config token_reviewer_jwt="$TOKEN_REVIEW_JWT" kubernetes_host="$KUBE_HOST" kubernetes_ca_cert="$KUBE_CA_CERT"

echo ""

pe "# On créé la policy"
cat manifests/policy.hcl
pe "vault policy write external-secrets-operator ./manifests/policy.hcl"

echo ""

pe "# On applique la policy à notre authent Kubernetes"
pe "vault write auth/external-secrets-operator/role/default bound_service_account_names=myapp bound_service_account_namespaces='myapp' policies=external-secrets-operator"

echo ""

pei "### dans Kube ###"
pe "# On déploie l'external-secrets-operator"
pei "helm repo add external-secrets https://charts.external-secrets.io"
pei "helm repo update"
pe "helm install external-secrets external-secrets/external-secrets -n external-secrets"

echo ""

pe "# On créé un ns applicatif myapp"
pe "kubectl create ns myapp"

echo ""

pe "# On créé un service account dans le ns myapp"
pe "kubectl create sa myapp -n myapp"

echo ""

pe "# On créé notre SecretStore dans le ns myapp"
p 'kubectl apply -f -n myapp - <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: demo-store
  namespace: myapp
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "kvv2"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "external-secrets-operator"
          role: "default"
          serviceAccountRef:
            name: myapp
EOF'
kubectl apply -f manifests/sstorebao.yaml -n myapp

echo ""

pe "# On créé un secret à pusher sur Vault"
p 'kubectl apply -f -n myapp - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-super-secret-credentials
  namespace: myapp
stringData:
  username: user_rw
  password: "password"
EOF'
kubectl apply -f manifests/secret.yaml -n myapp

echo ""

pe "# On créé un PushSecret"
p "kubectl apply -f -n myapp - <<EOF
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: pushsecret
  namespace: myapp
spec:
  data:
    - conversionStrategy: None
      match:
        remoteRef:
          remoteKey: demo/myapp/config
  deletionPolicy: Delete
  refreshInterval: 10s
  secretStoreRefs:
    - kind: SecretStore
      name: demo-store
  selector:
    secret:
      name: my-super-secret-credentials
  updatePolicy: Replace
EOF"
kubectl apply -f manifests/pushsecret.yaml -n myapp

echo ""

pe "# On vérifie que le secret a été créé dans Vault"
pe "vault kv get kvv2/demo/myapp/config"

echo ""

pe "# On créé un external secret"
p "kubectl apply -f -n myapp - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: external-secret-myapp
  namespace: myapp
spec:
  refreshInterval: "15s"
  secretStoreRef:
    name: demo-store
    kind: SecretStore
  target:
    name: my-super-secret
  dataFrom:
  - extract:
      key: kvv2/demo/myapp/config
EOF"
kubectl apply -f manifests/externalsecret.yaml -n myapp

echo ""

pe "# On créé notre déploiement"
echo "kubectl apply -f -n myapp - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: myapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      volumes:
      - name: secret-volume
        secret:
          secretName: my-super-secret
      containers:
        - name: myapp
          image: alpine:latest
          command:
            ['sh', '-c']
          args:
            ['echo -e "Mon user est :\n" ; cat /secret/mot-de-passe-top-secret/username ; echo -e "\n" ; echo -e "Mon mdp à absolument ne pas faire fuiter est :\n" ; cat /secret/mot-de-passe-top-secret/password ; echo -e "\n" ; sleep 3600']
          ports:
            - containerPort: 9090
          volumeMounts:
            - name: secret-volume
              readOnly: true
              mountPath: "/secret/mot-de-passe-top-secret"
EOF"
wait
kubectl apply -f manifests/myapp.yaml -n myapp

echo ""

pe "# On déploie le reloader"
pei "helm repo add stakater https://stakater.github.io/stakater-charts"
pei "helm repo update"
pe "helm install reloader -n external-secrets stakater/reloader --create-namespace"

echo ""

pe "# On annote notre déploiement pour le reloader"
p 'kubectl annotate deployment myapp -n myapp secret.reloader.stakater.com/reload: "my-super-secret"'

pe "# On change le secret dans Vault"
p 'kubectl apply -f -n myapp - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-super-secret-credentials
  namespace: myapp
stringData:
  username: user_rw
  password: "p@ssw0rd!"
EOF'
kubectl apply -f manifests/secretchange.yaml -n myapp

wait

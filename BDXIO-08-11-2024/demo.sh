#!/bin/zsh

clear

. ../demo-magic.sh

pe "# Creation d'un ns"
pe "kubectl create ns vault"
pei "kubens vault"

echo ""

pe "# Création du service account"
pe "kubectl create sa operator-auth -n vault"

echo ""

pe "# Création d'un token pour le SA"
p "kubectl apply -f -n vault - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: operator-auth
  annotations:
    kubernetes.io/service-account.name: operator-auth
type: kubernetes.io/service-account-token
EOF"

kubectl apply -f secretsa.yaml 

echo ""

pe "# Création du clusterrolebinding pour le service account operator-auth"
pe "kubectl create clusterrolebinding role-tokenreview-binding \
--clusterrole=system:auth-delegator \
--serviceaccount=vault:operator-auth"

echo ""

pe "# Récupération du token, du ca cert et du host"
p "TOKEN_REVIEW_JWT=\$(kubectl get secret operator-auth -n vault --output='go-template={{ .data.token }}' | base64 --decode)"
export TOKEN_REVIEW_JWT=$(kubectl get secret operator-auth -n vault --output='go-template={{ .data.token }}' | base64 --decode)
p "KUBE_CA_CERT=\$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.certificate-authority-data}' | base64 --decode)"
export KUBE_CA_CERT=$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.certificate-authority-data}' | base64 --decode)
p "KUBE_HOST=\$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.server}')"
export KUBE_HOST=$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.server}')

echo ""

pe "# Ajouter le repo Hashicorp à Helm"
pe "helm repo add hashicorp https://helm.releases.hashicorp.com"
pe "helm repo update"

echo ""

pe "# On créé un Vault"
pe "helm install vault hashicorp/vault --set 'server.dev.enabled=true'"

echo ""

pe "# On expose le port 8200"
pe "kubectl port-forward pod/vault-0 8200 2>&1 > /dev/null &"

echo ""

pe "# On exporte nos variables VAULT_ADDR et VAULT_TOKEN"
pe "export VAULT_ADDR=http://localhost:8200"
pe "export VAULT_TOKEN='root'"

echo ""

pei "### Dans Vault ###"
pe "# On créé le Secret Engine"
pe "vault secrets enable -path=kvv2 kv-v2"

echo ""

pe "# On créé le secret"
pe "vault kv put kvv2/demo/config username='user_rw' password='password'"

echo ""

pe "# On créé l'authent Kube"
pe "vault auth enable -path vault-secret-operator kubernetes"

echo ""

pe "# On configure l'authent Kube"
p "vault write auth/vault-secret-operator/config token_reviewer_jwt='\$TOKEN_REVIEW_JWT' kubernetes_host='\$KUBE_HOST' kubernetes_ca_cert='\$KUBE_CA_CERT'" 

vault write auth/vault-secret-operator/config token_reviewer_jwt="$TOKEN_REVIEW_JWT" kubernetes_host="$KUBE_HOST" kubernetes_ca_cert="$KUBE_CA_CERT"

echo ""

pe "# On créé la policy"
cat policy.hcl
pe "vault policy write vault-secret-operator ./policy.hcl"

echo ""

pe "# On applique la policy à notre authent Kubernetes"
pe "vault write auth/vault-secret-operator/role/default bound_service_account_names=operator-auth bound_service_account_namespaces='*' policies=vault-secret-operator"

echo ""

pei "### Sur Kube ###"
pe "# On déploie notre opérateur"
pe "helm install vault-secrets-operator hashicorp/vault-secrets-operator -n vault"

echo ""

pe "# On créé notre VaultConnection"
p "kubectl apply -f -n vault - <<EOF
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: myvaultconnection
  namespace: vault
spec:
  address: http://vault.vault.svc.cluster.local:8200 
  skipTLSVerify: false
EOF"
kubectl apply -f vaultco.yaml -n vault

echo ""

pe "# On créé notre VaultAuth"
p "kubectl apply -f -n vault - <<EOF
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: myvaultauth
spec:
  allowedNamespaces:
  - '*'
  vaultConnectionRef: myvaultconnection
  method: kubernetes
  mount: vault-secret-operator
  kubernetes:
    role: default
    serviceAccount: operator-auth
EOF"
kubectl apply -f vaultauth.yaml -n vault

echo ""

pe "# On créé un ns myapp"
pe "kubectl create ns myapp"
pei "kubens myapp"

echo ""

pe "# On créé notre VaultStaticSecret"
p "kubectl apply -f -n myapp - <<EOF
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: vault-static-secret
spec:
  vaultAuthRef: vault/myvaultauth
  mount: kvv2
  type: kv-v2
  path: demo/config
  refreshAfter: 10s
  destination:
    create: true
    name: my-super-secret
  rolloutRestartTargets:
  - kind: Deployment
    name: myapp
EOF"
kubectl apply -f vaultstaticsecret.yaml -n myapp

echo ""

pe "# On créé le SA operator-auth dans le ns myapp"
pe "kubectl create sa operator-auth -n myapp"

echo ""

pe "# On créé notre déploiment"
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
kubectl apply -f myapp.yaml -n myapp

echo ""

pe "# On change le secret dans Vault"
pe "vault kv put kvv2/demo/config username='user_rw' password='Passw0rd!'"

wait


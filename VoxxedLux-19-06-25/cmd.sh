kubectl create sa operator-auth -n external-secrets

kubectl apply -f - <<EOF                            
apiVersion: v1
kind: Secret
metadata:
  name: operator-auth
  annotations:
    kubernetes.io/service-account.name: operator-auth
type: kubernetes.io/service-account-token
EOF

kubectl create clusterrolebinding role-tokenreview-binding \
--clusterrole=system:auth-delegator \
--serviceaccount=external-secrets:operator-auth

export TOKEN_REVIEW_JWT=$(kubectl get secret operator-auth -n external-secrets --output='go-template={{ .data.token }}' | base64 --decode)
export KUBE_CA_CERT=$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.certificate-authority-data}' | base64 --decode)
export KUBE_HOST=$(kubectl config view --raw --minify --flatten --output='jsonpath={.clusters[].cluster.server}')


helm install vault hashicorp/vault --set "server.dev.enabled=true"

export VAULT_ADDR='http://[::]:8200'
export VAULT_TOKEN="root"

vault secrets enable -path=kvv2 kv-v2

vault kv put kvv2/demo/config username='user_rw' password='password'

vault auth enable -path external-secrets-operator kubernetes

vault write auth/external-secrets-operator/config token_reviewer_jwt="$TOKEN_REVIEW_JWT" kubernetes_host="$KUBE_HOST" kubernetes_ca_cert="$KUBE_CA_CERT"

vault policy write external-secrets-operator ./policy.hcl

vault write auth/external-secrets-operator/role/default bound_service_account_names=myapp bound_service_account_namespaces='myapp' policies=external-secrets-operator

helm install reloader stakater/reloader



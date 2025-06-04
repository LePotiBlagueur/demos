#!/bin/bash

clear

. ../demo-magic.sh

pe "# Déploiement de Kyverno"
pei "helm repo add kyverno https://kyverno.github.io/kyverno/"
pei "helm repo update"
pe 'helm upgrade --install kyverno --namespace kyverno kyverno/kyverno --create-namespace --set features.policyExceptions.enabled=true --set features.policyExceptions.namespace="*"'

echo ""

pe "# On applique notre première clusterPolicy" 
pe 'cat manifests/require-run-as-non-root.yaml'
pe 'kubectl apply -f manifests/require-run-as-non-root.yaml'

echo ""

pe "# On déploie un pod qui ne respecte pas la policy"
p 'kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  namespace: default
  name: kyverno-root-demo
spec:
  securityContext:
    runAsNonRoot: false
  containers:
  - name: root-container
    image: busybox:latest
    command: [ "sh", "-c", "sleep 1h" ]
EOF'

kubectl apply -f manifests/pod-root.yaml

echo ""

pe "# On check les events du pod"
pe "kubectl events --for po/kyverno-root-demo -n default"

echo ""

pe "# On edit la policy afin de la rendre bloquante"
pe "kubectl patch clusterpolicy require-run-as-nonroot --type='json' -p='[{'op': 'replace', 'path': '/spec/validationFailureAction', 'value': 'Enforce'}]'"

echo ""

pe "# On redéploie notre pod"
pe "kubectl --namespace default get pod kyverno-root-demo -o yaml | kubectl replace --force --save-config -f -"

echo ""

pe "# On ajoute une policyException"
pe "cat manifests/exception-require-run-as-nonroot.yaml"
pe "kubectl apply -f manifests/exception-require-run-as-nonroot.yaml"

echo ""

pe "# On ajoute une annotation à notre pod"
p 'kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  namespace: default
  name: kyverno-root-demo
  annotations:
    deezer.com/exception-require-run-as-nonroot: skip
spec:
  securityContext:
    runAsNonRoot: false
  containers:
  - name: root-container
    image: busybox:latest
    command: [ "sh", "-c", "sleep 1h" ]
EOF'

kubectl apply -f manifests/pod-root-annotated.yaml

echo ""

pe "# On ajoute une mutating rule"
pe "cat manifests/mutating-rule-policy.yaml"

kubectl apply -f manifests/mutating-rule-policy.yaml

echo ""

pe "# On check l'imagePullPolicy du pod"
pe "kubectl get pod -n default kyverno-root-demo -o yaml | grep imagePullPolicy"

echo ""

pe "# On redéploie le pod"
pe "kubectl --namespace default get pod kyverno-root-demo -o yaml | kubectl replace --force --save-config -f -"

echo ""

pe "# On Re-check l'imagePullPolicy du pod"
pe "kubectl get pod -n default kyverno-root-demo -o yaml | grep imagePullPolicy"

wait

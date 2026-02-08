#!/usr/bin/env bash
# Deploy Prometheus + Grafana + Node Exporter on K3s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

if [[ -f "$PROJECT_DIR/.env" ]]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi

GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-admin}"
if [[ "$GRAFANA_PASS" == "admin" ]]; then
  echo "WARNING: default Grafana password. Set GRAFANA_ADMIN_PASSWORD in .env."
fi

echo "[1/4] Deploying monitoring namespace + Prometheus..."
kubectl apply -f "$PROJECT_DIR/k8s/monitoring/prometheus.yaml"

echo "[2/4] Creating Grafana credentials secret..."
kubectl -n monitoring create secret generic grafana-credentials \
  --from-literal=admin-password="${GRAFANA_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[3/4] Deploying Grafana + Node Exporter..."
kubectl apply -f "$PROJECT_DIR/k8s/monitoring/grafana.yaml"
kubectl apply -f "$PROJECT_DIR/k8s/monitoring/node-exporter.yaml"

echo "  Waiting for pods to be ready..."
kubectl -n monitoring rollout status deployment/prometheus --timeout=120s || true
kubectl -n monitoring rollout status deployment/grafana --timeout=120s || true

echo "[4/4] Verifying..."
kubectl -n monitoring get pods

echo ""
echo "Prometheus: kubectl -n monitoring port-forward svc/prometheus 9090:9090"
echo "Grafana:    kubectl -n monitoring port-forward svc/grafana 3000:3000"
echo "Login:      admin / ${GRAFANA_PASS}"

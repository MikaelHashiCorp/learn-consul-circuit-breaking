#!/bin/bash
#
# Restore public-api service to normal operation
# This script undoes the failure simulation by reapplying the original service configuration
#

set -e

echo "Restoring public-api service to normal operation..."
echo "This will:"
echo "  - Re-enable health checks on public-api ServiceDefaults"
echo "  - Set ERROR_RATE back to 0 for all public-api instances (v1, v2, v3)"
echo ""

# Apply the original service configuration
kubectl apply --filename k8s-services/service-public-api.yaml

echo ""
echo "The service instances will now:"
echo "  - Return successful responses (ERROR_RATE=0)"
echo "  - Have passive health checks enabled"
echo ""
echo "Wait a couple of minutes for the pods to restart and metrics to stabilize."
echo "You can monitor the status with:"
echo "  kubectl get pods -l app=public-api"
echo "  kubectl rollout status deployment/public-api-v1"
echo "  kubectl rollout status deployment/public-api-v2"
echo "  kubectl rollout status deployment/public-api-v3"

echo ""
echo -n "Waiting for pods to restart: "
for i in {1..12}; do echo -n "."; sleep 5; done
echo " Done!"
kubectl get pods -l app=public-api
kubectl rollout status deployment/public-api-v1
kubectl rollout status deployment/public-api-v2
kubectl rollout status deployment/public-api-v3
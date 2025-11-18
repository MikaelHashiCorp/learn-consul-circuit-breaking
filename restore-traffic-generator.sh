#!/bin/bash
# Script to restore traffic-generator ServiceDefaults to original configuration
# This backs out the changes from servicedefaults-traffic-generator.yaml

set -e

echo "Restoring traffic-generator ServiceDefaults to original configuration..."

# Apply the original simple ServiceDefaults configuration
kubectl apply -f - <<EOF
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceDefaults
metadata:
  name: traffic-generator
  namespace: default
spec:
  protocol: "http"
EOF

echo "✓ traffic-generator ServiceDefaults restored successfully"
echo "The upstreamConfig (timeouts, limits, and passive health checks) has been removed"

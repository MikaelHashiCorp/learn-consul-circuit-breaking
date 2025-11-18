#!/bin/bash
#
# Check the failure status of public-api service
# Shows which instances are configured to return errors
#

echo "=========================================="
echo "Checking public-api failure configuration"
echo "=========================================="
echo ""

echo "1. Deployment ERROR_RATE settings:"
echo "----------------------------"
for deploy in public-api-v1 public-api-v2 public-api-v3; do 
  echo -n "$deploy: ERROR_RATE="
  kubectl get deployment $deploy -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ERROR_RATE")].value}'
  echo ""
done

echo ""
echo "2. Pod status:"
echo "----------------------------"
kubectl get pods -l app=public-api -o wide

echo ""
echo "3. ServiceDefaults health check config:"
echo "----------------------------"
kubectl get servicedefaults public-api -o yaml | grep -A 10 "upstreamConfig:" || echo "No upstreamConfig found (health checks enabled by default)"

echo ""
echo "4. Recent HTTP errors (last 30 seconds):"
echo "----------------------------"
# Get logs from last 30 seconds using --since flag
CURRENT_TIME=$(date -u +%s)
SINCE_TIME=$((CURRENT_TIME - 30))
ERROR_COUNT_30s=$(kubectl logs -l app=traffic-generator -c traffic-generator --since=30s 2>/dev/null | grep -c '"code":500')
ERROR_COUNT_30s=${ERROR_COUNT_30s:-0}

if [ "$ERROR_COUNT_30s" -gt 0 ]; then
  echo "⚠️  Found $ERROR_COUNT_30s HTTP 500 errors in the last 30 seconds"
  echo ""
  echo "Most recent error (last 5):"
  kubectl logs -l app=traffic-generator -c traffic-generator --since=30s 2>/dev/null | grep '"code":500' | tail -5
else
  echo "✅ No HTTP 500 errors in the last 30 seconds - all instances healthy!"
fi

echo ""
echo "5. Error trend analysis:"
echo "----------------------------"
ERROR_1min=$(kubectl logs -l app=traffic-generator -c traffic-generator --since=1m 2>/dev/null | grep -c '"code":500')
ERROR_5min=$(kubectl logs -l app=traffic-generator -c traffic-generator --since=5m 2>/dev/null | grep -c '"code":500')
ERROR_1min=${ERROR_1min:-0}
ERROR_5min=${ERROR_5min:-0}

echo "Errors in last 1 minute:  $ERROR_1min"
echo "Errors in last 5 minutes: $ERROR_5min"
echo ""
if [ "$ERROR_1min" -eq 0 ]; then
  echo "✅ Status: All instances are healthy (no recent errors)"
elif [ "$ERROR_1min" -gt 0 ] && [ "$ERROR_5min" -gt 50 ]; then
  echo "📈 Status: Recovering from failure state (errors decreasing)"
else
  echo "⚠️  Status: Instances are experiencing failures"
fi

echo ""
echo "NOTE: Fortio only logs errors. For complete metrics, check Consul UI:"
echo "  kubectl port-forward -n consul svc/consul-ui 8500:443"
echo "  Then visit: https://localhost:8500/ui/dc1/services/public-api"

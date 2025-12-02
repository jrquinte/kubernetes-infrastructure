# Resource Right-Sizing Guide for Guestbook Deployment

## 📋 Current vs Recommended Resources

### Before (Original)
```yaml
requests:
  cpu: 50m
  memory: 64Mi
limits:
  cpu: 100m
  memory: 128Mi
```

### After (Production-Ready - Recommended)
```yaml
requests:
  cpu: 100m      # +100% (2x increase)
  memory: 256Mi  # +300% (4x increase)
limits:
  cpu: 200m      # +100% (2x increase)
  memory: 512Mi  # +300% (4x increase)
```

### Cost Impact Analysis
- **Per pod**: ~2x cost increase (but much more stable)
- **Total cluster**: Depends on autoscaling behavior
- **Benefits**: Fewer OOMKilled errors, better performance, reduced troubleshooting

---

## 🚀 Deployment Steps

### Step 1: Install metrics-server (if not already installed)
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Wait for metrics-server to be ready
kubectl wait --for=condition=available --timeout=300s deployment/metrics-server -n kube-system
```

### Step 2: Baseline Current Usage (BEFORE changes)
```bash
# Get current metrics
kubectl top pods -l app=guestbook

# Get detailed container metrics
kubectl top pods -l app=guestbook --containers

# Save baseline
kubectl top pods -l app=guestbook > /tmp/baseline-before.txt
```

### Step 3: Apply Updated Configuration
```bash
# Option A: Update via kubectl (if using deployment.yaml file)
kubectl apply -f deployment-rightsized.yaml

# Option B: Update via CI/CD pipeline
# (Your GitHub Actions workflow will apply it)

# Watch the rollout
kubectl rollout status deployment/guestbook

# Monitor pod recreation
kubectl get pods -l app=guestbook -w
```

### Step 4: Verify Changes Applied
```bash
# Check the new resource configuration
kubectl describe deployment guestbook | grep -A 10 "Limits:"

# Verify on actual pods
kubectl get pods -l app=guestbook -o jsonpath='{range .items[*]}{.metadata.name}{"\n  Requests: CPU="}{.spec.containers[0].resources.requests.cpu}{", Memory="}{.spec.containers[0].resources.requests.memory}{"\n  Limits: CPU="}{.spec.containers[0].resources.limits.cpu}{", Memory="}{.spec.containers[0].resources.limits.memory}{"\n\n"}{end}'
```

---

## 📊 Monitoring After Deployment

### Immediate Monitoring (First 15 minutes)
```bash
# Watch pod status
kubectl get pods -l app=guestbook -w

# Check for OOMKilled or CrashLoopBackOff
kubectl get events --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp' | grep guestbook

# Monitor resource usage
watch -n 5 'kubectl top pods -l app=guestbook'
```

### Short-term Monitoring (First Hour)
```bash
# Check HPA behavior
kubectl get hpa guestbook-hpa -w

# View detailed HPA metrics
kubectl describe hpa guestbook-hpa

# Check if pods are being throttled (CPU)
kubectl describe pods -l app=guestbook | grep -A 5 "cpu"
```

### Long-term Monitoring (24-48 hours)
```bash
# Generate usage report
cat << 'EOF' > check-usage.sh
#!/bin/bash
echo "=== Resource Usage Report ==="
echo "Date: $(date)"
echo ""
echo "Current Pod Metrics:"
kubectl top pods -l app=guestbook --containers
echo ""
echo "HPA Status:"
kubectl get hpa guestbook-hpa
echo ""
echo "Pod Count:"
kubectl get pods -l app=guestbook --no-headers | wc -l
EOF

chmod +x check-usage.sh

# Run every hour
*/60 * * * * /path/to/check-usage.sh >> /tmp/usage-log.txt
```

---

## 🎯 Success Criteria

### ✅ Deployment Successful When:
1. All pods are in `Running` state
2. No `OOMKilled` events in last 24 hours
3. CPU utilization stays below 70% of limits
4. Memory utilization stays below 80% of limits
5. Response times remain consistent
6. No throttling warnings in pod descriptions

### ❌ Red Flags to Watch:
1. Pods stuck in `Pending` state → Insufficient cluster capacity
2. `OOMKilled` errors → Memory limits still too low
3. CPU throttling messages → CPU limits too low
4. HPA constantly scaling up/down → Adjust thresholds
5. Increased latency → Application under resource pressure

---

## 📈 Validation Queries

### Check Pod Health
```bash
# All pods healthy?
kubectl get pods -l app=guestbook

# Any recent restarts?
kubectl get pods -l app=guestbook -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'

# Any error events?
kubectl get events --field-selector involvedObject.kind=Pod,type!=Normal | grep guestbook
```

### Resource Utilization Check
```bash
# Current usage vs requests
kubectl top pods -l app=guestbook --containers | awk 'NR>1 {print $1, "CPU:", $2, "MEM:", $3}'

# Compare to requests (100m CPU, 256Mi memory)
# - CPU should be < 100m under normal load
# - Memory should be < 256Mi under normal load
```

### HPA Behavior Validation
```bash
# Check HPA metrics
kubectl get hpa guestbook-hpa -o yaml | grep -A 20 "currentMetrics:"

# Ensure HPA is functioning
kubectl describe hpa guestbook-hpa | grep -A 10 "Conditions:"
```

### Load Testing (Optional)
```bash
# Install Apache Bench or use existing load generator
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: load-generator
spec:
  containers:
  - name: load-generator
    image: busybox
    command: ["/bin/sh"]
    args: ["-c", "while true; do wget -q -O- http://guestbook.default.svc.cluster.local; done"]
EOF

# Monitor during load test
watch -n 2 'kubectl top pods -l app=guestbook'
```

---

## 🔧 Troubleshooting Common Issues

### Issue 1: Pods Stuck in Pending
**Symptom:** New pods won't schedule
**Cause:** Insufficient node capacity for new resource requests
**Solution:**
```bash
# Check node capacity
kubectl describe nodes | grep -A 5 "Allocated resources"

# Option A: Add more nodes (scale node group)
# Option B: Reduce resource requests temporarily
```

### Issue 2: OOMKilled After Upgrade
**Symptom:** Pods killed with OOM errors
**Cause:** Memory limit still too low for actual usage
**Solution:**
```bash
# Check memory usage before OOM
kubectl describe pod <pod-name> | grep -A 10 "Last State"

# Increase memory limits further (try Option 3: 512Mi/1Gi)
```

### Issue 3: CPU Throttling
**Symptom:** Application slow, CPU at limit
**Cause:** CPU limit too restrictive
**Solution:**
```bash
# Check throttling
kubectl describe pods -l app=guestbook | grep -i throttl

# Increase CPU limits or reduce CPU-intensive operations
```

### Issue 4: High Cost
**Symptom:** AWS bill increased significantly
**Cause:** More resources allocated
**Solution:**
```bash
# Use Option 2 (Conservative) instead
# Or implement cluster autoscaler to scale down unused nodes
# Or use Spot instances for cost savings (already in your config)
```

---

## 🎓 Next Steps for Optimization

### 1. Enable Vertical Pod Autoscaler (VPA)
```bash
# Install VPA (for automatic right-sizing recommendations)
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler
./hack/vpa-up.sh

# Create VPA for guestbook
kubectl apply -f - <<EOF
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: guestbook-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: guestbook
  updatePolicy:
    updateMode: "Off"  # Recommendation mode only
EOF

# Check VPA recommendations
kubectl describe vpa guestbook-vpa
```

### 2. Implement Resource Quotas (Namespace-level limits)
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: guestbook-quota
  namespace: default
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
EOF
```

### 3. Monitor with Prometheus/Grafana
- Set up Prometheus for detailed metrics
- Create dashboards for resource utilization
- Set alerts for OOM, throttling, etc.

---

## 📚 References

- [Kubernetes Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Node.js Memory Management](https://nodejs.org/en/docs/guides/simple-profiling/)
- [AWS EKS Best Practices - Resource Management](https://aws.github.io/aws-eks-best-practices/scalability/docs/control-plane/)

---

## ✨ Summary

**Recommended Action:** Apply Option 1 (Production-Ready) configuration

**Expected Outcome:**
- ✅ Fewer OOMKilled errors
- ✅ Better application stability
- ✅ Improved response times
- ✅ More predictable autoscaling
- ⚠️ ~2x cost increase per pod (justified by stability gains)

**Timeline:**
- Deploy: 5 minutes
- Initial validation: 15 minutes
- Short-term monitoring: 1 hour
- Full validation: 24-48 hours

Good luck with your right-sizing! 🚀

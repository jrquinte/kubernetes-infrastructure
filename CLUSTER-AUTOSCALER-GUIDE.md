# Cluster Autoscaler Setup and Operations Guide

## 📋 Overview

The Kubernetes Cluster Autoscaler automatically adjusts the number of nodes in your cluster based on pod resource requests. When pods cannot be scheduled due to insufficient resources, the autoscaler adds nodes. When nodes are underutilized, it removes them.

## 🎯 How It Works

### Scale Up (Add Nodes)
1. Pods cannot be scheduled (Pending state) due to insufficient CPU/memory
2. Autoscaler detects unschedulable pods
3. Autoscaler increases the Auto Scaling Group desired capacity
4. New nodes join the cluster
5. Pending pods get scheduled on new nodes

### Scale Down (Remove Nodes)
1. Node utilization is below threshold (default: 50%)
2. All pods on the node can be moved elsewhere
3. Node is drained (pods evicted gracefully)
4. Node is terminated
5. Auto Scaling Group desired capacity decreases

## 🚀 Deployment Steps

### Step 1: Update Terraform Configuration

Add the following to your `main.tf`:

```bash
# Copy the IAM configuration
cat terraform-cluster-autoscaler.tf >> infrastructure/main.tf

# Or manually add the content from terraform-cluster-autoscaler.tf
```

**Verify node group tags are present:**
```hcl
eks_managed_node_groups = {
  default = {
    # ... other config ...
    
    tags = {
      "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      "k8s.io/cluster-autoscaler/enabled"             = "true"
    }
  }
}
```

### Step 2: Apply Terraform Changes

```bash
cd infrastructure

# Plan the changes
terraform plan

# Review the output - should create:
# - aws_iam_policy.cluster_autoscaler
# - module.cluster_autoscaler_irsa

# Apply the changes
terraform apply

# Save the IAM role ARN
terraform output cluster_autoscaler_iam_role_arn
```

### Step 3: Deploy Kubernetes Components

```bash
# Make the deployment script executable
chmod +x deploy-cluster-autoscaler.sh

# Run the deployment script
./deploy-cluster-autoscaler.sh
```

**Or deploy manually:**

```bash
# Get the IAM role ARN
ROLE_ARN=$(terraform output -raw cluster_autoscaler_iam_role_arn)
CLUSTER_NAME="k8s-learning-cluster"

# Substitute variables in manifest
sed -e "s|\${CLUSTER_AUTOSCALER_ROLE_ARN}|$ROLE_ARN|g" \
    -e "s|\${CLUSTER_NAME}|$CLUSTER_NAME|g" \
    cluster-autoscaler.yaml > cluster-autoscaler-final.yaml

# Apply the manifest
kubectl apply -f cluster-autoscaler-final.yaml

# Wait for deployment
kubectl wait --for=condition=available --timeout=300s \
    deployment/cluster-autoscaler -n kube-system
```

## ✅ Verification

### Check Deployment Status
```bash
# View deployment
kubectl get deployment cluster-autoscaler -n kube-system

# View pods
kubectl get pods -n kube-system -l app=cluster-autoscaler

# Check pod logs
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50

# Follow logs in real-time
kubectl logs -f -n kube-system -l app=cluster-autoscaler
```

### Verify Configuration
```bash
# Check ServiceAccount annotation (should have IAM role ARN)
kubectl get sa cluster-autoscaler -n kube-system -o yaml | grep eks.amazonaws.com/role-arn

# Verify RBAC permissions
kubectl describe clusterrole cluster-autoscaler

# Check node groups have correct tags
aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[?Tags[?Key=='k8s.io/cluster-autoscaler/enabled']].[AutoScalingGroupName,MinSize,MaxSize,DesiredCapacity]" \
    --output table
```

### Expected Log Output (Success)
```
I0115 12:00:00.000000       1 leaderelection.go:248] attempting to acquire leader lease kube-system/cluster-autoscaler...
I0115 12:00:00.000000       1 leaderelection.go:258] successfully acquired lease kube-system/cluster-autoscaler
I0115 12:00:15.000000       1 static_autoscaler.go:230] Starting main loop
I0115 12:00:15.000000       1 utils.go:595] No pod using affinity / antiaffinity found in cluster, disabling affinity predicate for this loop
I0115 12:00:15.000000       1 static_autoscaler.go:348] Filtering out schedulables
I0115 12:00:15.000000       1 static_autoscaler.go:365] No unschedulable pods
```

## 🧪 Testing Autoscaling

### Test 1: Scale Up (Add Nodes)

Create a load generator that requests more resources than available:

```bash
# Deploy the test workload
kubectl apply -f load-generator.yaml

# Watch nodes (in another terminal)
watch kubectl get nodes

# Watch pods
watch kubectl get pods

# Monitor autoscaler logs
kubectl logs -f -n kube-system -l app=cluster-autoscaler

# View autoscaler events
kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep cluster-autoscaler
```

**What to look for:**
- Pods stuck in `Pending` state
- Autoscaler logs: `Scale-up: group ... -> ... (max: ...)`
- New nodes appearing in `kubectl get nodes`
- Pending pods transitioning to `Running`

### Test 2: Scale Down (Remove Nodes)

```bash
# Delete the load generator
kubectl delete -f load-generator.yaml

# Watch nodes - should decrease after ~10 minutes
watch kubectl get nodes

# Monitor autoscaler logs
kubectl logs -f -n kube-system -l app=cluster-autoscaler | grep -i "scale.down"
```

**Scale-down criteria (all must be met):**
- Node utilization < 50% for 10 minutes (default)
- All pods can be moved to other nodes
- No pods with local storage (unless --skip-nodes-with-local-storage=false)
- No pods that prevent eviction (PodDisruptionBudget)

## 📊 Monitoring

### View Cluster Capacity
```bash
# Current node count
kubectl get nodes

# Node resource allocation
kubectl describe nodes | grep -A 5 "Allocated resources"

# Node utilization (requires metrics-server)
kubectl top nodes
```

### View Auto Scaling Group Status
```bash
# List ASG details
aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[*].[AutoScalingGroupName,MinSize,MaxSize,DesiredCapacity,Instances[*].InstanceId]" \
    --output table

# View scaling activities
aws autoscaling describe-scaling-activities \
    --auto-scaling-group-name <ASG_NAME> \
    --max-records 20
```

### View Autoscaler Metrics
```bash
# Check ConfigMap for status
kubectl get configmap cluster-autoscaler-status -n kube-system -o yaml

# View autoscaler pod resource usage
kubectl top pod -n kube-system -l app=cluster-autoscaler
```

## ⚙️ Configuration Options

### Key Command-Line Flags

Current configuration in deployment:
```yaml
command:
  - ./cluster-autoscaler
  - --v=4                                    # Verbosity level (0-10)
  - --cloud-provider=aws                     # Cloud provider
  - --skip-nodes-with-local-storage=false    # Scale down nodes with local storage
  - --expander=least-waste                   # Node selection strategy
  - --balance-similar-node-groups            # Balance pods across similar node groups
  - --skip-nodes-with-system-pods=false      # Allow scaling down nodes with system pods
  - --node-group-auto-discovery=asg:tag=...  # Auto-discover node groups
```

### Expander Strategies

- **least-waste**: Select node group that will have least idle CPU/memory (recommended)
- **most-pods**: Select node group that can schedule the most pods
- **priority**: Select node group based on priority (requires ConfigMap)
- **random**: Random selection
- **price**: Select cheapest node group (experimental)

### Scale-Down Configuration

Control scale-down behavior:
```yaml
# Add these flags to customize scale-down
- --scale-down-delay-after-add=10m          # Wait 10m after scale-up before considering scale-down
- --scale-down-unneeded-time=10m            # Node must be unneeded for 10m before scale-down
- --scale-down-utilization-threshold=0.5    # Node utilization must be < 50%
- --max-node-provision-time=15m             # Max time to wait for node to become ready
```

## 🔧 Troubleshooting

### Issue 1: Autoscaler Not Scaling Up

**Symptoms:** Pods stay in Pending, but no new nodes added

**Diagnoses:**
```bash
# Check autoscaler logs for errors
kubectl logs -n kube-system -l app=cluster-autoscaler | grep -i error

# Verify IAM permissions
kubectl logs -n kube-system -l app=cluster-autoscaler | grep -i "unable to\|unauthorized\|forbidden"

# Check ASG limits
aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[*].[AutoScalingGroupName,MinSize,MaxSize,DesiredCapacity]" \
    --output table
```

**Solutions:**
- Ensure IAM role has correct permissions
- Verify ASG max size is not reached
- Check node group tags are correct
- Ensure pods have resource requests defined

### Issue 2: Autoscaler Not Scaling Down

**Symptoms:** Underutilized nodes not removed

**Diagnoses:**
```bash
# Check why nodes cannot be removed
kubectl logs -n kube-system -l app=cluster-autoscaler | grep -i "not scaled down"

# Check for pods preventing eviction
kubectl get pods --all-namespaces -o wide | grep <NODE_NAME>

# Check for PodDisruptionBudgets
kubectl get pdb --all-namespaces
```

**Common blockers:**
- Pods without controller (standalone pods)
- Pods with local storage
- Kube-system pods (unless --skip-nodes-with-system-pods=false)
- PodDisruptionBudgets preventing eviction
- Node age < scale-down-delay-after-add

### Issue 3: Pods Evicted During Scale-Down

**Symptoms:** Application downtime during scale-down

**Solutions:**
```yaml
# Add PodDisruptionBudget to protect critical pods
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: guestbook-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: guestbook
```

### Issue 4: IAM Permission Errors

**Symptoms:** Logs show "AccessDenied" or "Unauthorized"

**Solution:**
```bash
# Verify IAM role annotation on ServiceAccount
kubectl get sa cluster-autoscaler -n kube-system -o yaml

# Check if IAM role exists
aws iam get-role --role-name k8s-learning-cluster-cluster-autoscaler

# Verify IAM policy attachment
aws iam list-attached-role-policies --role-name k8s-learning-cluster-cluster-autoscaler
```

## 📝 Best Practices

### 1. Always Define Resource Requests
```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 200m
    memory: 512Mi
```

Without requests, autoscaler cannot determine if pods are unschedulable.

### 2. Use Pod Disruption Budgets
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 2  # or maxUnavailable: 1
  selector:
    matchLabels:
      app: my-app
```

### 3. Set Appropriate ASG Limits
```hcl
eks_managed_node_groups = {
  default = {
    min_size     = 1   # Minimum for high availability
    max_size     = 10  # Reasonable maximum to prevent runaway costs
    desired_size = 2   # Initial size
  }
}
```

### 4. Configure HPA Alongside Cluster Autoscaler
- **HPA**: Scales pods horizontally
- **Cluster Autoscaler**: Scales nodes to accommodate pods

They work together:
1. HPA adds pods due to high CPU/memory
2. Pods can't be scheduled (no capacity)
3. Cluster Autoscaler adds nodes
4. Pods get scheduled on new nodes

### 5. Use Multiple Node Groups
```hcl
eks_managed_node_groups = {
  general = {
    instance_types = ["t3.medium"]
    min_size     = 1
    max_size     = 5
  }
  
  compute = {
    instance_types = ["c5.xlarge"]
    min_size     = 0
    max_size     = 10
    
    labels = {
      workload-type = "compute-intensive"
    }
    
    taints = [{
      key    = "compute"
      value  = "true"
      effect = "NoSchedule"
    }]
  }
}
```

### 6. Monitor Costs
```bash
# Set up budget alerts (see LEARNING_GUIDE.md)
# Monitor node count regularly
# Review autoscaler logs for unexpected scaling
```

## 🎓 Cost Optimization Tips

1. **Use Spot Instances for non-critical workloads**
   ```hcl
   capacity_type = "SPOT"
   ```

2. **Set aggressive scale-down settings** (if acceptable for your workload)
   ```yaml
   - --scale-down-delay-after-add=5m
   - --scale-down-unneeded-time=5m
   ```

3. **Use cluster-autoscaler priority expander** to prefer cheaper instance types

4. **Right-size your pods** to pack more efficiently

5. **Use node affinity** to group workloads on fewer nodes

## 📚 Additional Resources

- [Cluster Autoscaler FAQ](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md)
- [AWS EKS Best Practices - Autoscaling](https://aws.github.io/aws-eks-best-practices/cluster-autoscaling/)
- [Kubernetes Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)

## 🎯 Quick Reference

### Common Commands
```bash
# View autoscaler status
kubectl get deployment cluster-autoscaler -n kube-system
kubectl get pods -n kube-system -l app=cluster-autoscaler
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=100

# Check cluster capacity
kubectl get nodes
kubectl top nodes
kubectl describe nodes | grep -A 5 "Allocated resources"

# View scaling events
kubectl get events -n kube-system --sort-by='.lastTimestamp' | grep autoscaler

# Check ASG status
aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[*].[AutoScalingGroupName,DesiredCapacity]"

# Force scale-down test
kubectl scale deployment <name> --replicas=0
```

### Important Files
- `terraform-cluster-autoscaler.tf` - IAM configuration
- `cluster-autoscaler.yaml` - Kubernetes deployment manifest
- `deploy-cluster-autoscaler.sh` - Automated deployment script
- `load-generator.yaml` - Test workload for scale-up testing

---

**Ready to enable autoscaling?** Run `./deploy-cluster-autoscaler.sh` to get started! 🚀

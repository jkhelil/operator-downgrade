#!/bin/bash
# OSP Downgrade Script - Simplified Production Version
# Purpose: Downgrade OpenShift Pipelines from 1.15.x to 1.14.x

set -e

echo "=========================================="
echo "OSP Downgrade Script (1.15.x → 1.14.x)"
echo "=========================================="
echo ""

BACKUP_DIR="osp-backup-$(date +%Y%m%d-%H%M%S)"

# ============================================
# PHASE 0: Pre-Flight Checks
# ============================================

echo "PHASE 0: Pre-Flight Checks"
echo "----------------------------------------"

# Check TektonConfig is Ready
echo "Checking TektonConfig status..."
if ! oc get tektonconfig config &>/dev/null; then
  echo "❌ ERROR: TektonConfig 'config' not found"
  exit 1
fi

CONFIG_READY=$(oc get tektonconfig config -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [[ "$CONFIG_READY" != "True" ]]; then
  echo "❌ ERROR: TektonConfig is not Ready"
  echo "Current status:"
  oc get tektonconfig config
  exit 1
fi
echo "  ✅ TektonConfig is Ready"
echo ""

# Get and verify current CSV is 1.15.x
echo "Verifying current operator version..."

# Check what CSV is actually deployed (not just what Subscription thinks)
ACTUAL_CSV=$(oc get csv -n openshift-operators -l operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators --no-headers 2>/dev/null | awk '{print $1}' | head -1)
SUBSCRIPTION_CSV=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators -o jsonpath='{.status.currentCSV}' 2>/dev/null)

if [[ -z "$ACTUAL_CSV" ]]; then
  echo "❌ ERROR: No CSV found in openshift-operators"
  exit 1
fi

echo "  Actual CSV deployed: $ACTUAL_CSV"
echo "  Subscription reports: $SUBSCRIPTION_CSV"

# Use the actual deployed CSV for verification
CURRENT_CSV="$ACTUAL_CSV"

if [[ ! "$CURRENT_CSV" =~ openshift-pipelines-operator-rh\.v1\.15\. ]]; then
  echo "❌ ERROR: Current CSV is not 1.15.x"
  echo "Current CSV: $CURRENT_CSV"
  echo "This script only supports downgrading from 1.15.x to 1.14.x"
  exit 1
fi
echo "  ✅ Verified as 1.15.x"
echo ""

# Backup TektonConfig
echo "Backing up TektonConfig..."
mkdir -p "$BACKUP_DIR"
oc get tektonconfig config -o yaml > "$BACKUP_DIR/tektonconfig-before.yaml"
echo "  ✅ Backup saved to: $BACKUP_DIR/tektonconfig-before.yaml"
echo ""

# Count user workloads
echo "Counting user workloads..."
PR_COUNT_BEFORE=$(oc get pipelineruns -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
TR_COUNT_BEFORE=$(oc get taskruns -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
TASK_COUNT=$(oc get tasks -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
PIPELINE_COUNT=$(oc get pipelines -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  PipelineRuns: $PR_COUNT_BEFORE"
echo "  TaskRuns: $TR_COUNT_BEFORE"
echo "  Tasks: $TASK_COUNT"
echo "  Pipelines: $PIPELINE_COUNT"
echo ""

# ============================================
# PHASE 1: Remove Old Operator
# ============================================

echo "PHASE 1: Removing Operator 1.15.x"
echo "----------------------------------------"

# Delete Subscription
echo "Deleting Subscription..."
oc delete subscription openshift-pipelines-operator-rh -n openshift-operators
echo "  ✅ Subscription deleted"
echo ""

# Delete CSV
echo "Deleting CSV: $CURRENT_CSV"
oc delete csv "$CURRENT_CSV" -n openshift-operators
echo "  ✅ CSV deleted"
echo ""

# Wait for operator pod removal
echo "Waiting for old operator to be removed..."
for i in {1..60}; do
  OPERATOR_PODS=$(oc get pods -n openshift-operators -l name=openshift-pipelines-operator --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$OPERATOR_PODS" -eq 0 ]]; then
    echo "  ✅ Old operator removed"
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

# ============================================
# PHASE 2: Install Operator 1.14.x
# ============================================

echo "PHASE 2: Installing Operator 1.14.x"
echo "----------------------------------------"

# Create new Subscription
echo "Creating Subscription for pipelines-1.14 channel..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: pipelines-1.14
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
echo "  ✅ Subscription created"
echo ""

# Wait for new CSV
echo "Waiting for new CSV to be created..."
for i in {1..60}; do
  NEW_CSV=$(oc get subscription openshift-pipelines-operator-rh -n openshift-operators -o jsonpath='{.status.currentCSV}' 2>/dev/null)
  if [[ -n "$NEW_CSV" ]] && [[ "$NEW_CSV" =~ v1\.14\. ]]; then
    echo "  ✅ New CSV: $NEW_CSV"
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

# Wait for operator pod
echo "Waiting for operator pod to be ready..."
for i in {1..60}; do
  READY_PODS=$(oc get pods -n openshift-operators -l name=openshift-pipelines-operator --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$READY_PODS" -ge 1 ]]; then
    echo "  ✅ Operator pod is running"
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

# Wait for webhook pod
echo "Waiting for operator webhook pod to be ready..."
for i in {1..60}; do
  WEBHOOK_POD=$(oc get pods -n openshift-operators -l name=tekton-operator-webhook --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$WEBHOOK_POD" -ge 1 ]]; then
    echo "  ✅ Operator webhook pod is running"
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

# ============================================
# PHASE 3: Fix Invalid Parameters
# ============================================

echo "PHASE 3: Fixing Invalid Parameters"
echo "----------------------------------------"

# Check if resolverTasks exists
if oc get tektonconfig config -o yaml 2>/dev/null | grep -q "resolverTasks"; then
  echo "Found resolverTasks parameter (invalid for 1.14.x) - removing..."
  echo ""
  
  # Retry patching with smart error detection
  PATCH_SUCCESS=false
  for attempt in {1..10}; do
    echo "Attempt $attempt: Patching TektonConfig..."
    
    # Temporarily disable exit on error for patch command
    set +e
    PATCH_OUTPUT=$(oc patch tektonconfig config --type='merge' -p '{"spec":{"addon":{"params":[{"name":"communityClusterTasks","value":"true"},{"name":"clusterTasks","value":"true"},{"name":"pipelineTemplates","value":"true"}]}}}' 2>&1)
    PATCH_RC=$?
    set -e
    
    if [[ $PATCH_RC -eq 0 ]]; then
      echo "  ✅ Removed resolverTasks from TektonConfig"
      PATCH_SUCCESS=true
      break
    elif echo "$PATCH_OUTPUT" | grep -q "tls: unrecognized name"; then
      echo "  ⏳ Webhook TLS certificates not ready yet, waiting..."
      sleep 10
    elif echo "$PATCH_OUTPUT" | grep -q "not found"; then
      echo "  ⏳ Webhook service not ready yet, waiting..."
      sleep 5
    else
      echo "  ❌ Unexpected error: $PATCH_OUTPUT"
      break
    fi
  done
  
  if [[ "$PATCH_SUCCESS" != "true" ]]; then
    echo "  ⚠️  Warning: Failed to patch TektonConfig"
    echo "  Please manually run:"
    echo "  oc patch tektonconfig config --type='merge' -p '{\"spec\":{\"addon\":{\"params\":[{\"name\":\"communityClusterTasks\",\"value\":\"true\"},{\"name\":\"clusterTasks\",\"value\":\"true\"},{\"name\":\"pipelineTemplates\",\"value\":\"true\"}]}}}'"
  fi
  echo ""
else
  echo "  ℹ️  No resolverTasks parameter found"
  echo ""
fi

# Wait for pipeline webhook (for TektonAddon reconciliation)
echo "Waiting for pipeline webhook to be ready..."
for i in {1..60}; do
  WEBHOOK_POD=$(oc get pods -n openshift-pipelines -l app.kubernetes.io/name=webhook --no-headers 2>/dev/null | grep "tekton-pipelines-webhook" | grep "Running" | wc -l | tr -d ' ')
  if [[ "$WEBHOOK_POD" -ge 1 ]]; then
    echo "  ✅ Pipeline webhook pod is running"
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

# ============================================
# PHASE 4: Wait for TektonConfig Ready
# ============================================

echo "PHASE 4: Waiting for TektonConfig Ready"
echo "----------------------------------------"

echo "Waiting for TektonConfig to be Ready (may take 2-3 minutes)..."
for i in {1..120}; do
  CONFIG_READY=$(oc get tektonconfig config -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  if [[ "$CONFIG_READY" == "True" ]]; then
    echo "  ✅ TektonConfig is Ready"
    break
  fi
  echo -n "."
  sleep 3
done
echo ""

# ============================================
# PHASE 5: Verification
# ============================================

echo "PHASE 5: Verification"
echo "----------------------------------------"

# Check TektonConfig version and status
NEW_VERSION=$(oc get tektonconfig config -o jsonpath='{.status.version}' 2>/dev/null)
CONFIG_READY=$(oc get tektonconfig config -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

echo "TektonConfig Status:"
oc get tektonconfig config
echo ""

if [[ ! "$NEW_VERSION" =~ ^1\.14\. ]]; then
  echo "❌ ERROR: Version is not 1.14.x"
  echo "Current version: $NEW_VERSION"
  exit 1
fi

if [[ "$CONFIG_READY" != "True" ]]; then
  echo "❌ ERROR: TektonConfig is not Ready"
  exit 1
fi

echo "  ✅ Version: $NEW_VERSION"
echo "  ✅ Status: Ready"
echo ""

# Check workload counts
echo "Verifying user workloads..."
PR_COUNT_AFTER=$(oc get pipelineruns -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
TR_COUNT_AFTER=$(oc get taskruns -A --no-headers 2>/dev/null | wc -l | tr -d ' ')

echo "  PipelineRuns: $PR_COUNT_BEFORE (before) → $PR_COUNT_AFTER (after)"
echo "  TaskRuns: $TR_COUNT_BEFORE (before) → $TR_COUNT_AFTER (after)"

if [[ "$PR_COUNT_BEFORE" -eq "$PR_COUNT_AFTER" ]] && [[ "$TR_COUNT_BEFORE" -eq "$TR_COUNT_AFTER" ]]; then
  echo "  ✅ All user workloads preserved"
else
  echo "  ⚠️  Warning: Workload count mismatch"
fi
echo ""

# Clean up old 1.15 InstallerSets
echo "Cleaning up old 1.15 InstallerSets..."
OLD_IS=$(oc get tektoninstallerset -o name 2>/dev/null | grep "1\.15" || true)
if [[ -n "$OLD_IS" ]]; then
  echo "$OLD_IS" | xargs -r oc delete --ignore-not-found=true
  echo "  ✅ Old InstallerSets deleted"
else
  echo "  ✅ No old InstallerSets found"
fi
echo ""

# ============================================
# Done
# ============================================

echo "=========================================="
echo "✅ DOWNGRADE COMPLETE"
echo "=========================================="
echo ""
echo "Downgraded from: $CURRENT_CSV"
echo "Downgraded to:   $NEW_CSV"
echo "Backup location: $BACKUP_DIR/"
echo ""

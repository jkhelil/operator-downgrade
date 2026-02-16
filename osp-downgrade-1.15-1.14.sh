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

# Check if pipelines-1.14 channel is available
echo "Checking if pipelines-1.14 channel is available..."
CHANNEL_CHECK=$(oc get packagemanifest openshift-pipelines-operator-rh -n openshift-marketplace -o json 2>/dev/null | jq -r '.status.channels[] | select(.name=="pipelines-1.14") | .name')

if [[ "$CHANNEL_CHECK" != "pipelines-1.14" ]]; then
  echo "❌ ERROR: pipelines-1.14 channel not found in catalog"
  echo "Available channels:"
  oc get packagemanifest openshift-pipelines-operator-rh -n openshift-marketplace -o jsonpath='{.status.channels[*].name}'
  echo ""
  echo "Cannot proceed with downgrade - target channel unavailable"
  exit 1
fi
echo "  ✅ pipelines-1.14 channel is available"
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

# Wait for CA bundle propagation in MutatingWebhookConfiguration
echo "Waiting for CA bundle to be injected into webhook configuration..."
for i in {1..30}; do
  CABUNDLE_SIZE=$(oc get mutatingwebhookconfigurations.admissionregistration.k8s.io webhook.operator.tekton.dev -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | wc -c | tr -d ' ')
  if [[ "$CABUNDLE_SIZE" -gt 100 ]]; then
    echo "  ✅ CA bundle populated ($CABUNDLE_SIZE bytes)"
    echo "  ⏳ Waiting 20s for webhook certificate to propagate and be loaded by pod..."
    sleep 20
    break
  fi
  if [[ $i -eq 1 ]]; then
    echo "  ⏳ CA bundle size: $CABUNDLE_SIZE bytes (waiting for service-ca-operator...)"
  elif [[ $((i % 5)) -eq 0 ]]; then
    echo "  ⏳ Still waiting... ($i/30, CA bundle: $CABUNDLE_SIZE bytes)"
  fi
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
  
  # Retry patching with timeout (120 seconds)
  PATCH_SUCCESS=false
  MAX_WAIT_TIME=120
  START_TIME=$(date +%s)
  ATTEMPT=0
  
  while true; do
    ATTEMPT=$((ATTEMPT + 1))
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    # Check timeout
    if [[ $ELAPSED -ge $MAX_WAIT_TIME ]]; then
      echo "  ⏱️  Timeout reached (${MAX_WAIT_TIME}s), stopping retries"
      break
    fi
    
    echo "Attempt $ATTEMPT: Patching TektonConfig... (${ELAPSED}s elapsed)"
    
    # Temporarily disable exit on error for patch command
    set +e
    PATCH_OUTPUT=$(oc patch tektonconfig config --type='merge' -p '{"spec":{"addon":{"params":[{"name":"communityClusterTasks","value":"true"},{"name":"clusterTasks","value":"true"},{"name":"pipelineTemplates","value":"true"}]}}}' 2>&1)
    PATCH_RC=$?
    set -e
    
    if [[ $PATCH_RC -eq 0 ]]; then
      echo "  ✅ Removed resolverTasks from TektonConfig (after ${ELAPSED}s)"
      PATCH_SUCCESS=true
      break
    else
      # Retry on ANY error - let timeout handle it
      echo "  ⏳ Patch failed, retrying in 5s..."
      if [[ $ATTEMPT -eq 1 ]] || [[ $((ATTEMPT % 3)) -eq 0 ]]; then
        # Show error every 3rd attempt to avoid spam
        echo "     Error: $PATCH_OUTPUT"
      fi
      sleep 5
    fi
  done
  
  if [[ "$PATCH_SUCCESS" != "true" ]]; then
    echo ""
    echo "  ⚠️  Warning: Failed to patch TektonConfig after ${MAX_WAIT_TIME}s"
    echo "  Last error: $PATCH_OUTPUT"
    echo ""
    echo "  To retry manually:"
    echo "  1. Wait 30-60 seconds for webhook CA bundle propagation"
    echo "  2. Run the patch command:"
    echo "     oc patch tektonconfig config --type='merge' -p '{\"spec\":{\"addon\":{\"params\":[{\"name\":\"communityClusterTasks\",\"value\":\"true\"},{\"name\":\"clusterTasks\",\"value\":\"true\"},{\"name\":\"pipelineTemplates\",\"value\":\"true\"}]}}}'"
    echo "  3. After successful patch, verify TektonConfig becomes Ready (wait ~1 minute):"
    echo "     oc get tektonconfig config -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'"
    echo ""
    echo "  To check webhook status:"
    echo "  oc get pods -n openshift-operators -l name=tekton-operator-webhook"
    echo "  oc get validatingwebhookconfigurations.admissionregistration.k8s.io webhook.operator.tekton.dev -o yaml | grep caBundle"
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

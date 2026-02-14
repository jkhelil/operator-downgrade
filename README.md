# OSP Downgrade Automation (1.15 → 1.14)

Automated script for safely downgrading OpenShift Pipelines from version 1.15 to 1.14 with comprehensive validation and error handling.

## Procedure

Follow these steps to test the downgrade automation:

1. **Install OpenShift 4.14**
   - Deploy a fresh OpenShift cluster version 4.14

2. **Install OpenShift Pipelines 1.15**
   - Deploy the OpenShift Pipelines Operator version 1.15

3. **Wait for operator to be healthy**
   - Ensure TektonConfig reaches Ready state
   - Verify all components are running

4. **Apply test workloads**
   - Run: `oc apply -f test-workloads.yaml`
   - This creates sample user workloads (PipelineRuns/TaskRuns)

5. **Execute the downgrade script**
   - Run: `./osp-downgrade-1.15-1.14.sh`
   - The script will handle the entire downgrade process with validation

## Safety & Validation

The script includes multiple safety mechanisms to ensure a reliable downgrade:

- **Version enforcement** - Script only runs for 1.15.x → 1.14.x downgrades (hard to enforce manually)
- **Pre-flight checks** - Verifies TektonConfig is Ready before starting
- **Automatic backup** - Captures TektonConfig before any changes
- **Workload verification** - Counts PipelineRuns/TaskRuns to ensure no user impact

## Technical Challenges Solved

### Webhook Timing Issues
Automated retry logic handles common errors that can mislead SRE teams:
- `tls: unrecognized name` (TLS certificates propagating)
- `service not found` (webhook pod starting)

### Smart Waiting
Detects specific errors and retries automatically instead of blind sleeps

### Parameter Cleanup
Removes invalid `resolverTasks` parameter that causes validation failures in 1.14

## Post-Downgrade Verification

The script performs comprehensive post-downgrade checks:

- ✅ Verifies TektonConfig is Ready with 1.14.x version
- ✅ Confirms workload counts match pre-downgrade
- ✅ Cleans up old 1.15 InstallerSets

#!/usr/bin/env bash
# mirrorpeer-storageclusterpeer-diag.sh
#
# Diagnose why ODF Regional-DR / Metro-DR peering is failing, looking at:
#   - MirrorPeer            (multicluster.odf.openshift.io/v1alpha1, cluster-
#                             scoped, lives on the ACM HUB)
#   - StorageClusterPeer    (ocs.openshift.io/v1, namespaced in the ODF
#                             namespace, lives on each MANAGED/SPOKE cluster)
#
# Run this same script against the hub and against each managed cluster
# (oc login to the right context first) -- it auto-detects which CRDs are
# present and only runs the sections that apply to that cluster.
#
# Usage:
#   ./mirrorpeer-storageclusterpeer-diag.sh [odf-namespace] [log-since]
#
#   odf-namespace  default: openshift-storage
#   log-since      default: 4h   (passed to `oc logs --since=`)
#
# Requires: oc (logged in, correct context), column.

set -uo pipefail

# Consistent section-header formatting for every check below.
section() {
  echo
  echo "----------------------------------------------------------------"
  echo " $1"
  echo "----------------------------------------------------------------"
}

NS="${1:-openshift-storage}"
LOG_SINCE="${2:-4h}"

OUT_DIR=$(mktemp -d)
MP_BAD_FILE="$OUT_DIR/mirrorpeer-issues.txt"
MC_BAD_FILE="$OUT_DIR/managedcluster-issues.txt"
MW_BAD_FILE="$OUT_DIR/manifestwork-issues.txt"
SCP_BAD_FILE="$OUT_DIR/storageclusterpeer-issues.txt"
SCP_ERR_FILE="$OUT_DIR/scpeer-log-errors.txt"
TEA_ERR_FILE="$OUT_DIR/tea-log-errors.txt"
ODFMO_ERR_FILE="$OUT_DIR/odfmo-log-errors.txt"
ADDON_BAD_FILE="$OUT_DIR/addon-issues.txt"
EP_BAD_FILE="$OUT_DIR/apiendpoint-issues.txt"
NC_BAD_FILE="$OUT_DIR/reachability-issues.txt"
TLS_BAD_FILE="$OUT_DIR/tls-secret-issues.txt"
LH_BAD_FILE="$OUT_DIR/lighthouse-issues.txt"
EGRESS_BAD_FILE="$OUT_DIR/egress-issues.txt"
: > "$MP_BAD_FILE"; : > "$MC_BAD_FILE"; : > "$MW_BAD_FILE"; : > "$SCP_BAD_FILE"; : > "$SCP_ERR_FILE"
: > "$TEA_ERR_FILE"
: > "$ODFMO_ERR_FILE"; : > "$ADDON_BAD_FILE"
: > "$EP_BAD_FILE"; : > "$NC_BAD_FILE"; : > "$TLS_BAD_FILE"; : > "$LH_BAD_FILE"; : > "$EGRESS_BAD_FILE"

echo "================================================================"
echo " MirrorPeer / StorageClusterPeer DR Peering Diagnostic"
echo "================================================================"
echo " ODF namespace : $NS"
echo " Log window    : $LOG_SINCE"
echo

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: 'oc' not found in PATH. Log in and re-run." >&2
  exit 1
fi
if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: not logged in to a cluster ('oc whoami' failed). Run 'oc login' first." >&2
  exit 1
fi

HAS_MIRRORPEER=0
HAS_SCPEER=0
oc get crd mirrorpeers.multicluster.odf.openshift.io >/dev/null 2>&1 && HAS_MIRRORPEER=1
oc get crd storageclusterpeers.ocs.openshift.io >/dev/null 2>&1 && HAS_SCPEER=1

if [ "$HAS_MIRRORPEER" -eq 0 ] && [ "$HAS_SCPEER" -eq 0 ]; then
  echo "Neither the MirrorPeer nor the StorageClusterPeer CRD exists on this"
  echo "cluster. This isn't an ACM hub with odf-multicluster-orchestrator"
  echo "installed, and isn't an ODF managed cluster with DR peering enabled."
  echo "Log in to the right cluster and re-run."
  exit 1
fi

[ "$HAS_MIRRORPEER" -eq 1 ] && echo " Detected role: ACM HUB              (MirrorPeer CRD present)"
[ "$HAS_SCPEER" -eq 1 ]     && echo " Detected role: MANAGED/SPOKE cluster (StorageClusterPeer CRD present)"
echo

# ===========================================================================
# HUB checks
# ===========================================================================
ALL_CLUSTERS=""
if [ "$HAS_MIRRORPEER" -eq 1 ]; then

  section "[HUB 1/5] MirrorPeer status"
  MP_LIST=$(oc get mirrorpeer -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,PHASE:.status.phase,MESSAGE:.status.message' --no-headers 2>/dev/null)
  if [ -z "$MP_LIST" ]; then
    echo "  No MirrorPeer resources found."
  else
    echo "$MP_LIST" | column -t -s $'\t' 2>/dev/null || echo "$MP_LIST"
    while read -r NAME TYPE PHASE MSG; do
      [ -z "$NAME" ] && continue
      if [ "$PHASE" != "Ready" ]; then
        echo "MirrorPeer=$NAME phase=$PHASE message=\"$MSG\"" >> "$MP_BAD_FILE"
      fi
    done <<< "$MP_LIST"
  fi
  echo

  ALL_CLUSTERS=$(oc get mirrorpeer -o jsonpath='{range .items[*]}{range .spec.items[*]}{.clusterName}{"\n"}{end}{end}' 2>/dev/null | sort -u)

  section "[HUB 2/5] ManagedCluster availability for MirrorPeer member clusters"
  if [ -z "$ALL_CLUSTERS" ]; then
    echo "  (no MirrorPeer member clusters to check)"
  else
    for C in $ALL_CLUSTERS; do
      AVAIL=$(oc get managedcluster "$C" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null)
      JOINED=$(oc get managedcluster "$C" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null)
      AVAIL=${AVAIL:-Unknown}; JOINED=${JOINED:-Unknown}
      printf "  %-30s Available=%-10s Joined=%-10s\n" "$C" "$AVAIL" "$JOINED"
      if [ "$AVAIL" != "True" ] || [ "$JOINED" != "True" ]; then
        echo "cluster=$C Available=$AVAIL Joined=$JOINED" >> "$MC_BAD_FILE"
      fi
    done
  fi
  echo

  section "[HUB 3/5] ODF Multicluster Orchestrator operator pod health + logs (-n openshift-operators)"
  ODFMO_PODS=$(oc get pods -n openshift-operators -l control-plane=odfmo-controller-manager -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' --no-headers 2>/dev/null)
  if [ -z "$ODFMO_PODS" ]; then
    ODFMO_PODS=$(oc get pods -A --no-headers 2>/dev/null | grep -i 'multicluster-orchestrator\|odfmo')
  fi
  if [ -z "$ODFMO_PODS" ]; then
    echo "  WARNING: no odf-multicluster-orchestrator (odfmo-controller-manager) pod found."
  else
    echo "$ODFMO_PODS" | column -t
  fi

  # Direct-evidence scan: each pattern below is a message fragment taken
  # verbatim from controllers/odf/mirrorpeer_controller.go in
  # red-hat-storage/odf-multicluster-orchestrator, paired with what it means.
  # A match here is the reconciler itself stating what's wrong or what it's
  # stuck waiting on -- not an inference from a raw log dump.
  ODFMO_RAW="$OUT_DIR/odfmo-raw.log"
  oc logs -n openshift-operators -l control-plane=odfmo-controller-manager \
    --all-containers --prefix --since="$LOG_SINCE" > "$ODFMO_RAW" 2>/dev/null

  ODFMO_CHECKS=(
    "Failed to get MirrorPeer::Reconciler can't even read the MirrorPeer object -- likely a transient apiserver/RBAC issue on the hub."
    "MirrorPeer validation failed::Spec-level problem: bad/duplicate/missing items, or a referenced ManagedCluster is invalid. See the accompanying 'error' field for which check failed."
    "MirrorPeer spec is undefined::The MirrorPeer has no spec.items -- it was created without the two peer cluster references."
    "MirrorPeer spec items are not unique::The same cluster/storageCluster is listed twice in spec.items -- fix the MirrorPeer spec."
    "MirrorPeer spec items have empty fields::One of spec.items[].clusterName / storageClusterRef is empty."
    "Invalid ManagedCluster::A clusterName in spec.items does not match a real ManagedCluster known to the hub -- check 'oc get managedcluster'."
    "Can not reconcile MirrorPeer::Reconciler gave up on this MirrorPeer after a validation error (see above)."
    "ConfigMap 'odf-client-info' not found. Requeueing::STUCK WAITING: the odf-client-info ConfigMap hasn't synced from one of the member clusters yet (provider-mode client info not yet available)."
    "Failed to determine if MirrorPeer contains StorageClient reference::Error while checking the storageClusterRef/StorageClient wiring for this MirrorPeer."
    "Failed to process managedclusteraddon::Error reconciling the per-cluster ManagedClusterAddOn (tokenexchange/etc.) for this MirrorPeer."
    "Failed to reconcile ClusterManagementAddOn::The cluster-scoped ClusterManagementAddOn couldn't be created/updated -- addon framework problem on the hub."
    "Failed to reconcile ManagedClusterAddOn::A per-cluster ManagedClusterAddOn couldn't be created/updated -- check 'oc describe managedclusteraddon <name> -n <cluster>'."
    "not available yet::STUCK WAITING: a required ManagedClusterAddOn has not reported Available=True yet."
    "Failed to create StorageClusterPeer::The hub could not build/push the StorageClusterPeer manifest for one of the member clusters."
    "Failed to marshal StorageClusterPeer to JSON::Internal error building the StorageClusterPeer object -- see the accompanying error detail."
    "failed to fetch onboarding token for provider::Could not get the onboarding token needed to peer with the provider cluster -- check the referenced Secret on that cluster."
    "'StorageProviderPublicEndpoint' not found. Using 'StorageProviderEndpoint' instead::The provider's public API endpoint isn't set -- falling back to an internal endpoint that may not be reachable from the peer cluster (a likely CONNECTION_FAILED root cause on the StorageClusterPeer)."
    "secret .* not found in namespace::A secret the reconciler expected (token/onboarding/client info) is missing in the given namespace."
    "failed to fetch secret::Error reading a secret the reconciler needed."
    "token data not found in secret::The expected secret exists but doesn't contain the token data key -- it was created/synced incorrectly."
    "Failed to create ManifestWork for ClusterPairingConfigMap::Could not push the cluster-pairing ConfigMap ManifestWork to a member cluster."
    "failed to get ManifestWork::Error reading back a ManifestWork the reconciler manages -- check ManifestWork objects in that cluster's namespace on the hub."
    "ManifestWork .* has no manifests::A ManifestWork exists but is empty/corrupted -- likely needs to be deleted so the reconciler recreates it."
    "failed to decode ConfigMap::Error decoding the cluster-pairing ConfigMap payload inside a ManifestWork."
    "failed to update ManifestWork for provider::Could not update an existing ManifestWork with new pairing info."
    "Failed to get client info from ConfigMap for the (first|second) cluster::Client info (from odf-client-info) for one of the two peer clusters is missing/unreadable -- provider-mode onboarding on that cluster hasn't completed."
    "failed to check if provider mode peering is correctly done::Error while verifying whether both the StorageClusterPeer and ClusterPairingConfigMap steps completed."
    "failed to get namespace for s3 secret::Could not resolve the namespace to look up the S3 bootstrap secret in (older, S3-based mirroring path)."
    "S3 secret is not yet synchronised. retrying::STUCK WAITING: the S3 bootstrap secret hasn't synced from the peer cluster to the hub yet (S3/manageS3 path)."
    "Error in fetching s3 internal secret::Error reading the internal S3 secret used for the (legacy) S3-based bootstrap exchange."
    "Error in creating S3 secret::Could not create/propagate the S3 secret to the peer cluster."
    "Error in updating Ramen Hub Operator config::Could not update Ramen's hub config with the new S3 profile -- DRPolicy/DRCluster creation downstream will be affected."
    "Secret not synchronised yet, retrying to create DRCluster::STUCK WAITING: a bootstrap secret hasn't synced yet, so DRCluster creation is being retried."
    "Failed to create DRClusters for MirrorPeer::DRCluster objects could not be created once secrets were ready -- check the Ramen hub operator."
    "failed to check StorageClusterPeer status::Error reading the StorageClusterPeer object's status back on the hub side."
    "failed to check if client pair config map has been created::Error verifying the cluster-pairing ConfigMap step."
    "Failed to unmarshal S3 secret::The S3 secret's data doesn't parse as expected -- it was corrupted or created with the wrong format."
    "DRPolicy .* exists and requires MirrorPeer .* can not be deleted::This MirrorPeer is protected by an active DRPolicy and can't be removed until that DRPolicy is deleted first."
    "Waiting for agent to delete resources::STUCK WAITING: MirrorPeer deletion is waiting on the tokenexchange agent to clean up on the managed clusters."
    "Failed to delete ManagedClusterAddon::Cleanup of the ManagedClusterAddOn failed during MirrorPeer deletion."
    "Failed to remove finalizer from MirrorPeer::MirrorPeer deletion is stuck because its finalizer couldn't be removed -- check for earlier errors in the same reconcile."
    "Error while deleting secrets for MirrorPeer::Cleanup of exchanged secrets failed during MirrorPeer deletion."
  )

  : > "$ODFMO_ERR_FILE"
  for entry in "${ODFMO_CHECKS[@]}"; do
    PATTERN="${entry%%::*}"
    EXPL="${entry#*::}"
    MATCHES=$(grep -iE "$PATTERN" "$ODFMO_RAW" 2>/dev/null)
    [ -z "$MATCHES" ] && continue
    HITS=$(echo "$MATCHES" | wc -l)
    LAST=$(echo "$MATCHES" | tail -n 1)
    {
      echo "  * (${HITS}x) $EXPL"
      echo "      -> $LAST"
    } >> "$ODFMO_ERR_FILE"
  done

  if [ -s "$ODFMO_ERR_FILE" ]; then
    echo "  -- direct evidence from odfmo-controller-manager (last $LOG_SINCE) --"
    cat "$ODFMO_ERR_FILE"
  else
    echo "  No known failure/stuck-waiting message from the MirrorPeer reconciler"
    echo "  found in odfmo-controller-manager logs (last $LOG_SINCE)."
  fi
  echo

  section "[HUB 4/5] tokenexchange ManagedClusterAddOn status"
  ADDON_ROWS=$(oc get managedclusteraddon -A --no-headers 2>/dev/null | grep -i tokenexchange)
  if [ -z "$ADDON_ROWS" ]; then
    echo "  No tokenexchange ManagedClusterAddOn found on this hub."
  else
    echo "$ADDON_ROWS" | column -t
    while read -r ADDON_NS ADDON_NAME REST; do
      [ -z "$ADDON_NS" ] && continue
      for COND in ManifestWorkApplied RegistrationApplied Degraded Available; do
        STATUS=$(oc get managedclusteraddon "$ADDON_NAME" -n "$ADDON_NS" -o jsonpath="{.status.conditions[?(@.type==\"$COND\")].status}" 2>/dev/null)
        REASON=$(oc get managedclusteraddon "$ADDON_NAME" -n "$ADDON_NS" -o jsonpath="{.status.conditions[?(@.type==\"$COND\")].reason}" 2>/dev/null)
        [ -z "$STATUS" ] && continue
        BAD=0
        if [ "$COND" = "Degraded" ] && [ "$STATUS" = "True" ]; then BAD=1; fi
        if [ "$COND" != "Degraded" ] && [ "$STATUS" != "True" ]; then BAD=1; fi
        if [ "$BAD" -eq 1 ]; then
          echo "cluster=$ADDON_NS addon=$ADDON_NAME condition=$COND status=$STATUS reason=${REASON:-none}" >> "$ADDON_BAD_FILE"
        fi
      done
    done <<< "$ADDON_ROWS"
  fi
  if [ -s "$ADDON_BAD_FILE" ]; then
    echo "  -- problem conditions --"
    cat "$ADDON_BAD_FILE"
  fi
  echo

  section "[HUB 5/5] ManifestWork status for MirrorPeer member clusters (peer/token/secret manifests)"
  for C in $ALL_CLUSTERS; do
    MW=$(oc get manifestwork -n "$C" --no-headers 2>/dev/null | grep -iE 'storageclusterpeer|mirror|token|secret')
    [ -z "$MW" ] && continue
    while read -r MWNAME REST; do
      [ -z "$MWNAME" ] && continue
      APPLIED=$(oc get manifestwork "$MWNAME" -n "$C" -o jsonpath='{.status.conditions[?(@.type=="Applied")].status}' 2>/dev/null)
      AVAILABLE=$(oc get manifestwork "$MWNAME" -n "$C" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
      APPLIED=${APPLIED:-Unknown}; AVAILABLE=${AVAILABLE:-Unknown}
      if [ "$APPLIED" != "True" ] || [ "$AVAILABLE" != "True" ]; then
        echo "cluster=$C manifestwork=$MWNAME Applied=$APPLIED Available=$AVAILABLE" >> "$MW_BAD_FILE"
      fi
    done <<< "$MW"
  done
  if [ -s "$MW_BAD_FILE" ]; then
    cat "$MW_BAD_FILE"
  else
    echo "  No problematic peer/token/secret-related ManifestWork found for the member clusters."
  fi
  echo
fi

# ===========================================================================
# MANAGED/SPOKE checks
# ===========================================================================
if [ "$HAS_SCPEER" -eq 1 ]; then

  section "[SPOKE 1/11] StorageClusterPeer status (-n $NS)"
  SCP_LIST=$(oc get storageclusterpeer -n "$NS" -o custom-columns='NAME:.metadata.name,STATE:.status.state,ENDPOINT:.spec.apiEndpoint' --no-headers 2>/dev/null)
  if [ -z "$SCP_LIST" ]; then
    echo "  No StorageClusterPeer resources found in $NS."
  else
    echo "$SCP_LIST" | column -t
    while read -r NAME STATE ENDPOINT; do
      [ -z "$NAME" ] && continue
      if [ "$STATE" != "Peered" ]; then
        REASON=$(oc get storageclusterpeer "$NAME" -n "$NS" -o jsonpath='{.status.conditions[?(@.status!="True")].reason}' 2>/dev/null)
        MSG=$(oc get storageclusterpeer "$NAME" -n "$NS" -o jsonpath='{.status.conditions[?(@.status!="True")].message}' 2>/dev/null)
        echo "StorageClusterPeer=$NAME state=$STATE endpoint=$ENDPOINT reason=${REASON:-none} message=\"${MSG:-}\"" >> "$SCP_BAD_FILE"
      fi
    done <<< "$SCP_LIST"
  fi
  echo

  section "[SPOKE 2/11] token-exchange-agent pod health (-n $NS)"
  TEA_PODS=$(oc get pods -n "$NS" -l app=token-exchange-agent -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' --no-headers 2>/dev/null)
  if [ -z "$TEA_PODS" ]; then
    TEA_PODS=$(oc get pods -n "$NS" --no-headers 2>/dev/null | grep token-exchange-agent)
  fi
  if [ -z "$TEA_PODS" ]; then
    echo "  No token-exchange-agent pod found in $NS."
  else
    echo "$TEA_PODS" | column -t
  fi
  echo

  # Direct-evidence patterns: each is a message fragment taken verbatim from
  # the actual reconcilers that run on this cluster --
  #   ocs-operator: internal/controller/storageclusterpeer/storageclusterpeer_controller.go
  #   tokenexchange addon agent: odf-multicluster-orchestrator/addons/{agent_mirrorpeer_controller,s3_secret_handler,onboarding_token}.go
  # paired with what it means. A match is the reconciler stating what's
  # wrong or what it's stuck waiting on -- not an inference from a raw dump.
  # Shared by the token-exchange-agent scan (below) and the ocs-operator/
  # rook-ceph scan (SPOKE 4/11), since both sets of source messages can show
  # up in either -- the addon agent and ocs-operator both talk about the
  # same StorageClusterPeer/MirrorPeer state.
  SCP_CHECKS=(
    # -- StorageClusterPeer controller (ocs-operator) --
    "Failed to get StorageClusterPeer\.::Reconciler can't even read the StorageClusterPeer object -- likely a transient apiserver/RBAC issue."
    "Could not update StorageClusterPeer status\.::A status update failed -- 'oc get storageclusterpeer' may be showing a stale state/reason."
    "failed to find StorageCluster owning the StorageClusterPeer::CLUSTER_NOT_FOUND cause: this StorageClusterPeer has no StorageCluster ownerRef set."
    "Error fetching StorageCluster for StorageClusterPeer found in the same namespace\.::CLUSTER_NOT_FOUND cause: error reading the owning StorageCluster object."
    "Cannot find a StorageCluster for StorageClusterPeer in the same namespace\.::CLUSTER_NOT_FOUND cause: the owning StorageCluster doesn't exist in this namespace."
    "Invalid onboarding ticket\. Does not conform to expected ticket structure::INVALID_ONBOARDING_TICKET cause: the token isn't in the expected '<payload>.<sig>' format."
    "failed to decode onboarding ticket::INVALID_ONBOARDING_TICKET cause: the ticket's base64 payload doesn't decode."
    "onboarding ticket message is not a valid JSON\.::INVALID_ONBOARDING_TICKET cause: the ticket payload decodes but isn't valid JSON."
    "failed to create a new provider client::CONNECTION_FAILED cause: couldn't open a gRPC client to spec.apiEndpoint -- check DNS, firewall, and Submariner path to that endpoint."
    "failed to Peer Storage Cluster, reason::The actual PeerStorageCluster gRPC call to the peer's provider server failed -- see the 'reason' text in the matched line."
    "failed to extract an HTTP status code from error::Unexpected/non-gRPC error talking to the peer -- treated as CONNECTION_FAILED."
    # -- tokenexchange addon agent (spoke-side MirrorPeer reconciler) --
    "Failed to retrieve MirrorPeer::The spoke agent can't read its MirrorPeer copy -- check ManifestWork delivery from the hub (see hub-side ManifestWork check)."
    "Failed to check if storage client ref exists::Error while checking the provider-mode/StorageClient wiring for this MirrorPeer on the spoke."
    "Failed to fetch StorageCluster for given namespace::The local StorageCluster is missing/unreadable in this namespace."
    "Failed to get current storage cluster ref::Error resolving this cluster's own storageClusterRef."
    "Failed to add finalizer to MirrorPeer::Couldn't add the agent's finalizer to the MirrorPeer -- apiserver write issue on the spoke."
    "Failed to create ODR S3 resources::Creating the S3 buckets/backingstore needed for DR failed on this cluster."
    "Failed to unmarshal the onboarding ticket data::The onboarding token stored for this MirrorPeer doesn't parse."
    "Failed to create StorageCluster peer token on the hub\.::Could not push a fresh onboarding token secret to the hub -- check connectivity/permissions to the hub apiserver."
    "failed to delete S3 buckets::Cleanup of S3 buckets failed during MirrorPeer deletion."
    # -- S3 secret exchange (legacy manageS3 path) --
    "failed to retrieve the secret .* in namespace .* in managed cluster::A secret needed for the S3/DR exchange is missing on this managed cluster."
    "failed to retrieve the config map .* in namespace .* in managed cluster::A ConfigMap needed for the exchange is missing on this managed cluster."
    "failed to find storage cluster ref using spoke cluster name .* from mirrorpeers::This cluster's name isn't found in any MirrorPeer's spec.items -- check the MirrorPeer definition on the hub."
    "failed to find client peerRef for current provider cluster::Couldn't resolve the paired peer cluster reference for this MirrorPeer."
    "failed to retrieve the S3 endpoint in namespace .* in managed cluster::The S3 endpoint secret/ConfigMap for this cluster is missing."
    "failed to create secret from the managed cluster secret .* for the hub cluster::Could not push this cluster's secret up to the hub for exchange."
    "failed to update existing secret .* on hub cluster::Could not update the already-exchanged secret on the hub."
    "failed to create secret .* on hub cluster::Could not create the exchanged secret on the hub."
    # -- onboarding token HTTP exchange --
    "failed to create http request::Error building the HTTP request to fetch/create an onboarding token."
    "http request failed::Network-level failure reaching the onboarding-token endpoint -- check Submariner/route/firewall path."
    "unexpected status code::The onboarding-token endpoint returned an unexpected HTTP status -- likely an auth/permission problem."
    "unable to generate StorageClusterPeer token\.::Could not generate the token secret for the peer StorageCluster."
    "failed to set owner reference for secret::Error setting ownership on the generated token secret."
    "token audience::A token-audience validation error occurred during token exchange (see KCS below)."
    # -- rbd-mirror / ceph mgr (verified via RH Regional-DR troubleshooting docs) --
    "blocklist::Ceph mgr blocklisting can silently stop scheduled rbd-mirror snapshots from triggering even when StorageClusterPeer/MirrorPeer look healthy (see workaround below)."
  )

  scan_evidence() {
    local raw="$1" outfile="$2"
    : > "$outfile"
    local entry pattern expl matches hits last
    for entry in "${SCP_CHECKS[@]}"; do
      pattern="${entry%%::*}"
      expl="${entry#*::}"
      matches=$(grep -iE "$pattern" "$raw" 2>/dev/null)
      [ -z "$matches" ] && continue
      hits=$(echo "$matches" | wc -l)
      last=$(echo "$matches" | tail -n 1)
      {
        echo "  * (${hits}x) $expl"
        echo "      -> $last"
      } >> "$outfile"
    done
  }

  section "[SPOKE 3/11] token-exchange-agent pod log errors (last $LOG_SINCE)"
  TEA_RAW="$OUT_DIR/tea-raw.log"
  : > "$TEA_RAW"
  TEA_POD_NAMES=$(oc get pods -n "$NS" -o name 2>/dev/null | grep token-exchange-agent)
  for POD in $TEA_POD_NAMES; do
    CONTAINERS=$(oc get "$POD" -n "$NS" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    for C in $CONTAINERS; do
      oc logs "$POD" -n "$NS" -c "$C" --since="$LOG_SINCE" 2>/dev/null | sed "s#^#[$POD/$C] #" >> "$TEA_RAW"
    done
  done
  scan_evidence "$TEA_RAW" "$TEA_ERR_FILE"
  if [ -s "$TEA_ERR_FILE" ]; then
    echo "  -- direct evidence from token-exchange-agent logs (last $LOG_SINCE) --"
    cat "$TEA_ERR_FILE"
  else
    echo "  No known failure message from the tokenexchange addon agent found in the scanned window."
  fi
  echo

  section "[SPOKE 4/11] ocs-operator / rook-ceph-mgr log errors (last $LOG_SINCE)"
  SCP_RAW="$OUT_DIR/scpeer-raw.log"
  : > "$SCP_RAW"
  CANDIDATE_PODS=$(oc get pods -n "$NS" -o name 2>/dev/null | grep -E 'ocs-operator|rook-ceph-operator|odf-operator-controller-manager|rook-ceph-mgr')
  for POD in $CANDIDATE_PODS; do
    CONTAINERS=$(oc get "$POD" -n "$NS" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    for C in $CONTAINERS; do
      oc logs "$POD" -n "$NS" -c "$C" --since="$LOG_SINCE" 2>/dev/null | sed "s#^#[$POD/$C] #" >> "$SCP_RAW"
    done
  done
  scan_evidence "$SCP_RAW" "$SCP_ERR_FILE"
  if [ -s "$SCP_ERR_FILE" ]; then
    echo "  -- direct evidence from ocs-operator/rook-ceph logs (last $LOG_SINCE) --"
    cat "$SCP_ERR_FILE"
  else
    echo "  No known failure message from the StorageClusterPeer reconciler found in the scanned window."
  fi
  echo

  section "[SPOKE 5/11] rbd-mirror daemon health (-n $NS)"
  RBDM_PODS=$(oc get pods -n "$NS" -l app=rook-ceph-rbd-mirror -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' --no-headers 2>/dev/null)
  if [ -z "$RBDM_PODS" ]; then
    echo "  No rbd-mirror daemon pod found -- expected until at least one"
    echo "  StorageClusterPeer/MirrorPeer completes bootstrap successfully."
  else
    echo "$RBDM_PODS" | column -t
  fi
  echo

  section "[SPOKE 6/11] Validate spec.apiEndpoint configuration on each StorageClusterPeer"
  EP_LIST=$(oc get storageclusterpeer -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"	"}{.spec.apiEndpoint}{"\n"}{end}' 2>/dev/null)
  if [ -z "$EP_LIST" ]; then
    echo "  (no StorageClusterPeer objects to validate)"
  else
    while IFS=$'\t' read -r SCNAME EP; do
      [ -z "$SCNAME" ] && continue
      if [ -z "$EP" ]; then
        printf "  %-30s apiEndpoint=<EMPTY>\n" "$SCNAME"
        echo "peer=$SCNAME apiEndpoint is EMPTY -- provider endpoint was never set" >> "$EP_BAD_FILE"
        continue
      fi
      printf "  %-30s apiEndpoint=%s\n" "$SCNAME" "$EP"
      # strip scheme if present, then expect host:port
      HOSTPORT=$(echo "$EP" | sed -E 's#^[a-zA-Z]+://##')
      HOST=$(echo "$HOSTPORT" | sed -E 's/:[0-9]+$//')
      PORT=$(echo "$HOSTPORT" | grep -oE '[0-9]+$')
      if [ -z "$HOST" ] || [ -z "$PORT" ]; then
        echo "peer=$SCNAME apiEndpoint=\"$EP\" does not look like host:port -- check for typos/missing port" >> "$EP_BAD_FILE"
      fi
    done <<< "$EP_LIST"
  fi
  echo

  section "[SPOKE 7/11] Test TCP reachability from the ocs-operator pod to each apiEndpoint"
  OCS_POD=$(oc get pods -n "$NS" -l name=ocs-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$OCS_POD" ] && OCS_POD=$(oc get pods -n "$NS" -o name 2>/dev/null | grep ocs-operator | head -n1 | sed 's#pod/##')
  if [ -z "$OCS_POD" ]; then
    echo "  WARNING: no ocs-operator pod found in -n $NS -- can't test reachability from here."
  elif [ -z "$EP_LIST" ]; then
    echo "  (no apiEndpoint to test)"
  else
    while IFS=$'\t' read -r SCNAME EP; do
      [ -z "$SCNAME" ] || [ -z "$EP" ] && continue
      HOSTPORT=$(echo "$EP" | sed -E 's#^[a-zA-Z]+://##')
      HOST=$(echo "$HOSTPORT" | sed -E 's/:[0-9]+$//')
      PORT=$(echo "$HOSTPORT" | grep -oE '[0-9]+$')
      [ -z "$HOST" ] || [ -z "$PORT" ] && continue
      RESULT=$(oc exec -n "$NS" "$OCS_POD" -- sh -c '
        h="$1"; p="$2"
        if command -v nc >/dev/null 2>&1; then
          nc -zv -w3 "$h" "$p" 2>&1
        elif command -v bash >/dev/null 2>&1; then
          bash -c "exec 3<>/dev/tcp/$h/$p" 2>&1 && echo "TCP connect to $h:$p succeeded" || echo "TCP connect to $h:$p FAILED"
        else
          echo "no nc or bash available in this container to test $h:$p"
        fi
      ' _ "$HOST" "$PORT" 2>&1)
      printf "  %-30s -> %s\n" "$SCNAME ($HOST:$PORT)" "$RESULT"
      if echo "$RESULT" | grep -qiE 'fail|refused|timed out|unreachable|no route|cannot|unable'; then
        echo "peer=$SCNAME endpoint=$HOST:$PORT result=\"$RESULT\"" >> "$NC_BAD_FILE"
      fi
    done <<< "$EP_LIST"
  fi
  echo

  section "[SPOKE 8/11] Local provider/ingress endpoint health (routes/services this cluster exposes)"
  echo "  (the PEER cluster's apiEndpoint above should resolve to one of these on THAT cluster --"
  echo "   re-run this script there to check its own routes/svc against its incoming apiEndpoint)"
  PROV_RS=$(oc get routes,svc -n "$NS" --no-headers 2>/dev/null | grep -iE 'provider|ocs-provider|rook-ceph-mon')
  if [ -z "$PROV_RS" ]; then
    echo "  No provider/ocs-provider/rook-ceph-mon route or service found in -n $NS."
  else
    echo "$PROV_RS" | column -t
  fi
  echo

  section "[SPOKE 9/11] TLS / peering secret check"
  SECRET_ROWS=$(oc get secrets -n "$NS" --no-headers 2>/dev/null | grep -iE 'onboarding|peer|token|provider-server|storage-provider')
  if [ -z "$SECRET_ROWS" ]; then
    echo "  No onboarding/peer/token/provider-server secret found in -n $NS."
  else
    echo "$SECRET_ROWS" | column -t
  fi
  TLS_LOG_HITS=$(cat "$TEA_RAW" "$SCP_RAW" 2>/dev/null | grep -iE 'x509|certificate|tls handshake|unknown authority|certificate has expired|certificate signed by unknown authority' | sort -u)
  if [ -n "$TLS_LOG_HITS" ]; then
    echo "  -- TLS-related lines found in operator/agent logs --"
    echo "$TLS_LOG_HITS" | sed 's/^/    /'
    echo "$TLS_LOG_HITS" > "$TLS_BAD_FILE"
  else
    echo "  No TLS/certificate-related errors found in the scanned log window."
  fi
  echo

  section "[SPOKE 10/11] Submariner ServiceExport/ServiceImport + Lighthouse DNS check (for clusterset.local endpoints)"
  HAS_SE_CRD=0; HAS_SI_CRD=0
  oc get crd serviceexports.multicluster.x-k8s.io >/dev/null 2>&1 && HAS_SE_CRD=1
  oc get crd serviceimports.multicluster.x-k8s.io >/dev/null 2>&1 && HAS_SI_CRD=1
  if [ "$HAS_SE_CRD" -eq 0 ]; then
    echo "  WARNING: CRD serviceexports.multicluster.x-k8s.io not found -- the"
    echo "  Kubernetes Multicluster Services (MCS) API isn't installed on this"
    echo "  cluster; Submariner Lighthouse cannot function without it."
    echo "CRD serviceexports.multicluster.x-k8s.io missing -- MCS API / Lighthouse not installed on this cluster" >> "$LH_BAD_FILE"
  fi
  if [ "$HAS_SI_CRD" -eq 0 ]; then
    echo "  WARNING: CRD serviceimports.multicluster.x-k8s.io not found -- the"
    echo "  Kubernetes Multicluster Services (MCS) API isn't installed on this"
    echo "  cluster; Submariner Lighthouse cannot function without it."
    echo "CRD serviceimports.multicluster.x-k8s.io missing -- MCS API / Lighthouse not installed on this cluster" >> "$LH_BAD_FILE"
  fi

  if [ "$HAS_SE_CRD" -eq 1 ]; then
    echo "  -- ServiceExport objects in -n $NS (what THIS cluster advertises to peers) --"
    SE_ROWS=$(oc get serviceexports.multicluster.x-k8s.io -n "$NS" --no-headers 2>/dev/null)
    if [ -z "$SE_ROWS" ]; then
      echo "  None found. If a peer needs to reach a service on THIS cluster via"
      echo "  clusterset.local (e.g. this cluster's ocs-provider-server), it must"
      echo "  be exported here first."
    else
      echo "$SE_ROWS" | column -t
      # Surface any non-Valid/non-Ready condition on each export.
      for SENAME in $(echo "$SE_ROWS" | awk '{print $1}'); do
        BADCOND=$(oc get serviceexports.multicluster.x-k8s.io "$SENAME" -n "$NS" -o jsonpath='{range .status.conditions[?(@.status!="True")]}{.type}={.status} reason={.reason} {end}' 2>/dev/null)
        if [ -n "$BADCOND" ]; then
          echo "    $SENAME: $BADCOND"
          echo "ServiceExport=$SENAME in -n $NS has a non-True condition: $BADCOND" >> "$LH_BAD_FILE"
        fi
      done
    fi

    echo "  -- ocs-provider-server export status (the service peers connect to) --"
    PROVIDER_SE=$(oc get serviceexports.multicluster.x-k8s.io ocs-provider-server -n "$NS" -o name 2>/dev/null)
    if [ -z "$PROVIDER_SE" ]; then
      echo "  NOT exported: no ServiceExport named 'ocs-provider-server' in -n $NS."
      echo "  Any peer whose apiEndpoint points at this cluster's ocs-provider-server"
      echo "  via clusterset.local cannot resolve it until this is exported."
      PROVIDER_SVC=$(oc get svc ocs-provider-server -n "$NS" -o name 2>/dev/null)
      if [ -z "$PROVIDER_SVC" ]; then
        echo "  The underlying Service 'ocs-provider-server' was not even found in -n $NS."
        echo "ocs-provider-server Service not found in -n $NS -- nothing to export" >> "$LH_BAD_FILE"
      else
        echo "ocs-provider-server Service exists in -n $NS but has no ServiceExport -- peers cannot resolve/reach it via clusterset.local" >> "$LH_BAD_FILE"
      fi
    else
      PSE_COND=$(oc get serviceexports.multicluster.x-k8s.io ocs-provider-server -n "$NS" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' 2>/dev/null)
      echo "  Exported. Conditions: ${PSE_COND:-none reported}"
      PSE_BADCOND=$(oc get serviceexports.multicluster.x-k8s.io ocs-provider-server -n "$NS" -o jsonpath='{range .status.conditions[?(@.status!="True")]}{.type}={.status} reason={.reason} {end}' 2>/dev/null)
      if [ -n "$PSE_BADCOND" ]; then
        echo "ocs-provider-server ServiceExport has a non-True condition: $PSE_BADCOND" >> "$LH_BAD_FILE"
      fi
    fi
  fi
  echo

  HAS_CLUSTERSET_EP=0
  if [ "$HAS_SI_CRD" -eq 1 ] && [ -n "${EP_LIST:-}" ]; then
    while IFS=$'\t' read -r SCNAME EP; do
      [ -z "$SCNAME" ] || [ -z "$EP" ] && continue
      HOSTPORT=$(echo "$EP" | sed -E 's#^[a-zA-Z]+://##')
      HOST=$(echo "$HOSTPORT" | sed -E 's/:[0-9]+$//')
      case "$HOST" in
        *.svc.clusterset.local)
          HAS_CLUSTERSET_EP=1
          # Lighthouse per-cluster DNS format: <cluster>.<svc>.<ns>.svc.clusterset.local
          STRIPPED=${HOST%.svc.clusterset.local}
          CLUSTERNAME=$(echo "$STRIPPED" | awk -F. '{print $1}')
          SVCNAME=$(echo "$STRIPPED" | awk -F. '{print $2}')
          SVCNS=$(echo "$STRIPPED" | awk -F. '{print $3}')
          echo "  peer=$SCNAME uses Lighthouse MCS DNS: cluster=$CLUSTERNAME service=$SVCNAME namespace=$SVCNS"

          SI=$(oc get serviceimports.multicluster.x-k8s.io -n "$SVCNS" --no-headers 2>/dev/null | grep -i "$SVCNAME")
          if [ -z "$SI" ]; then
            echo "    No ServiceImport for '$SVCNAME' found in -n $SVCNS on this cluster."
            echo "peer=$SCNAME service=$SVCNAME namespace=$SVCNS: no ServiceImport (serviceimports.multicluster.x-k8s.io) on this cluster -- the $CLUSTERNAME cluster's ServiceExport likely never synced" >> "$LH_BAD_FILE"
          else
            echo "    ServiceImport found:"
            echo "$SI" | sed 's/^/      /'
          fi
          ;;
      esac
    done <<< "$EP_LIST"
  fi

  if [ "$HAS_CLUSTERSET_EP" -eq 1 ]; then
    echo "  -- Lighthouse component health --"
    LH_AGENT_PODS=$(oc get pods -A -l app=submariner-lighthouse-agent -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' --no-headers 2>/dev/null)
    LH_DNS_PODS=$(oc get pods -A -l app=submariner-lighthouse-coredns -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount' --no-headers 2>/dev/null)
    if [ -z "$LH_AGENT_PODS" ]; then
      echo "  WARNING: no submariner-lighthouse-agent pod found -- ServiceExport/ServiceImport sync will not work."
      echo "submariner-lighthouse-agent pod not found -- ServiceExport/ServiceImport sync will not work" >> "$LH_BAD_FILE"
    else
      echo "$LH_AGENT_PODS" | column -t
    fi
    if [ -z "$LH_DNS_PODS" ]; then
      echo "  WARNING: no submariner-lighthouse-coredns pod found -- nothing can answer clusterset.local DNS queries."
      echo "submariner-lighthouse-coredns pod not found -- clusterset.local DNS resolution will fail cluster-wide" >> "$LH_BAD_FILE"
    else
      echo "$LH_DNS_PODS" | column -t
    fi

    echo "  -- cluster DNS forwarding for clusterset.local --"
    FWD=$(oc get configmap dns-default -n openshift-dns -o yaml 2>/dev/null | grep -A3 'clusterset\.local')
    if [ -z "$FWD" ]; then
      echo "  WARNING: no 'clusterset.local' forward stanza found in the dns-default ConfigMap."
      echo "dns-default ConfigMap has no clusterset.local forward stanza -- this cluster's CoreDNS may not be wired to Lighthouse" >> "$LH_BAD_FILE"
    else
      echo "$FWD" | sed 's/^/    /'
    fi
  else
    echo "  (no apiEndpoint uses a clusterset.local hostname -- skipping)"
  fi
  echo

  section "[SPOKE 11/11] Egress policy check: is egress from -n $NS to the peer host:port allowed?"
  NP_EGRESS=$(oc get networkpolicy -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"	"}{.spec.policyTypes}{"\n"}{end}' 2>/dev/null | grep -i Egress)
  if [ -n "$NP_EGRESS" ]; then
    echo "  NetworkPolicy object(s) with an Egress policyType found in -n $NS:"
    echo "$NP_EGRESS" | column -t
    echo "$(echo "$NP_EGRESS" | wc -l) NetworkPolicy object(s) in $NS restrict Egress -- verify they explicitly allow the peer's host:port (a policy with an empty 'egress:' list denies ALL egress)" >> "$EGRESS_BAD_FILE"
  else
    echo "  No NetworkPolicy with an Egress policyType found in -n $NS (egress is not restricted by NetworkPolicy)."
  fi

  EF_ROWS=$(oc get egressfirewall -n "$NS" --no-headers 2>/dev/null)
  if [ -n "$EF_ROWS" ]; then
    echo "  EgressFirewall object(s) found (OVN-Kubernetes) in -n $NS:"
    echo "$EF_ROWS" | column -t
    oc get egressfirewall -n "$NS" -o yaml 2>/dev/null | grep -E 'name:|type:|cidrSelector:|dnsName:|nodeSelector:| +ports:| +- (port|protocol):' | sed 's/^/    /'
    echo "EgressFirewall present in -n $NS -- check its rule order/CIDR/dnsName/port entries against the peer apiEndpoint host:port above" >> "$EGRESS_BAD_FILE"
  fi

  ENP_ROWS=$(oc get egressnetworkpolicy -n "$NS" --no-headers 2>/dev/null)
  if [ -n "$ENP_ROWS" ]; then
    echo "  EgressNetworkPolicy object(s) found (legacy OpenShift SDN) in -n $NS:"
    echo "$ENP_ROWS" | column -t
    oc get egressnetworkpolicy -n "$NS" -o yaml 2>/dev/null | grep -E 'name:|type:|cidrSelector:|dnsName:' | sed 's/^/    /'
    echo "EgressNetworkPolicy present in -n $NS -- check its rule order/CIDR/dnsName entries against the peer apiEndpoint host:port above" >> "$EGRESS_BAD_FILE"
  fi

  if [ -z "$NP_EGRESS" ] && [ -z "$EF_ROWS" ] && [ -z "$ENP_ROWS" ]; then
    echo "  No egress-restricting NetworkPolicy/EgressFirewall/EgressNetworkPolicy found in -n $NS."
  fi
  echo
fi

# ===========================================================================
# COMMON: Submariner connectivity (DR peering traffic and/or gRPC provider
# endpoint traffic between clusters typically rides Submariner tunnels)
# ===========================================================================
section "[COMMON] Submariner connectivity"
if oc get crd clusters.submariner.io >/dev/null 2>&1; then
  echo "  -- submariner-operator pods --"
  oc get pods -n submariner-operator -o wide --no-headers 2>/dev/null | column -t || echo "  (none found in submariner-operator)"
  echo "  -- gateways --"
  oc get gateways.submariner.io -n submariner-operator -o wide --no-headers 2>/dev/null | column -t || echo "  (none found)"
  echo "  -- cluster connections --"
  oc get clusters.submariner.io -n submariner-operator -o wide --no-headers 2>/dev/null | column -t || echo "  (none found)"
else
  echo "  Submariner CRDs not present on this cluster -- skipping."
fi
echo


# ===========================================================================
# Report + Action Items
# ===========================================================================
ACTION_TITLES=()
ACTION_BODIES=()
add_action() { ACTION_TITLES+=("$1"); ACTION_BODIES+=("$2"); }

KCS_7007854_SHOWN=0
SUPPRESS_CONN=0
if [ -s "$NC_BAD_FILE" ] || [ -s "$LH_BAD_FILE" ]; then
  SUPPRESS_CONN=1
fi

if [ -s "$MP_BAD_FILE" ]; then
  BODY=$(sed 's/^/    /' "$MP_BAD_FILE"; cat <<'EOF'

    Check the ManagedCluster availability and ManifestWork results above for
    the member clusters first -- a MirrorPeer usually can't progress past
    Initializing/Configuring if a member cluster is unreachable from the hub
    or its peer manifest failed to apply. If both are healthy, check the
    odf-multicluster-orchestrator pod logs above for the reconcile error.

    Docs: Regional-DR troubleshooting chapter
      https://docs.redhat.com/documentation/en-us/red_hat_openshift_data_foundation/4.18/html/configuring_openshift_data_foundation_disaster_recovery_for_openshift_workloads/index
EOF
)
  add_action "MirrorPeer(s) not Ready" "$BODY"
fi

if [ -s "$MC_BAD_FILE" ]; then
  BODY=$(sed 's/^/    /' "$MC_BAD_FILE"; cat <<'EOF'

    A MirrorPeer/StorageClusterPeer cannot peer while the ACM hub can't reach
    the managed cluster's klusterlet. Check klusterlet and registration-agent
    pod health on that managed cluster, and hub-side ManagedCluster events:
      oc describe managedcluster <name>

    Docs: RHACM Troubleshooting guide
      https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.9/html-single/troubleshooting/index
EOF
)
  add_action "ManagedCluster(s) not Available/Joined" "$BODY"
fi

if [ -s "$MW_BAD_FILE" ]; then
  BODY=$(sed 's/^/    /' "$MW_BAD_FILE"; cat <<'EOF'

    This means the hub could not push the peering/secret/token manifest down
    to that managed cluster. Common cause: klusterlet-work-agent on the
    managed cluster can't reach the hub apiserver, or a cert/trust problem
    (e.g. "x509: certificate signed by unknown authority"). Check:
      oc get manifestwork <name> -n <cluster> -o yaml
      (on the managed cluster) oc get pods -n open-cluster-management-agent

    Docs: RHACM Troubleshooting guide
      https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.9/html-single/troubleshooting/index
EOF
)
  add_action "ManifestWork(s) not Applied/Available on the member cluster namespace" "$BODY"
fi

if [ -s "$ADDON_BAD_FILE" ]; then
  BODY=$(sed 's/^/    /' "$ADDON_BAD_FILE"; cat <<'EOF'

    ManifestWorkApplied=False means the hub couldn't push the addon's
    manifest to that managed cluster (see ManifestWork finding above, if
    present). RegistrationApplied=False means the addon's RBAC/registration
    on the hub failed -- check the cluster-manager-registration-controller
    pod on the hub. Degraded=True means the addon agent itself is unhealthy
    on the managed cluster; describe it for the full reason:
      oc describe managedclusteraddon tokenexchange -n <managed-cluster-name>
    and check the agent pod logs in the managed cluster's ODF namespace.
EOF
)
  add_action "tokenexchange ManagedClusterAddOn has a bad condition" "$BODY"
fi

if [ -s "$ODFMO_ERR_FILE" ]; then
  EXTRA=""
  if grep -qi "token audience" "$ODFMO_ERR_FILE" && [ "$KCS_7007854_SHOWN" -eq 0 ]; then
    EXTRA="
    KCS: Encountered \"client is not within the token audience\" error during Token Exchange
         https://access.redhat.com/solutions/7007854"
    KCS_7007854_SHOWN=1
  fi
  BODY=$(sed 's/^/    /' "$ODFMO_ERR_FILE"; cat <<EOF

    This is the hub-side reconciler for MirrorPeer/StorageClusterPeer/token
    exchange -- these lines are usually the most direct evidence of why a
    MirrorPeer is stuck.$EXTRA
EOF
)
  add_action "odfmo-controller-manager (ODF Multicluster Orchestrator) logged matching errors" "$BODY"
fi

if [ -s "$SCP_BAD_FILE" ]; then
  EXTRA=""
  if grep -q CLUSTER_NOT_FOUND "$SCP_BAD_FILE"; then
    EXTRA="${EXTRA}
    CLUSTER_NOT_FOUND: the peer cluster name/reference in the onboarding
    ticket doesn't match what the peer's OCS provider API server knows
    about itself. Recheck the MirrorPeer's spec.items[].clusterName /
    storageClusterRef on the hub against the actual managed cluster name."
  fi
  if grep -q INVALID_ONBOARDING_TICKET "$SCP_BAD_FILE"; then
    EXTRA="${EXTRA}
    INVALID_ONBOARDING_TICKET: the ticket is expired, was already consumed,
    or was generated against a different peer/public key. Onboarding
    tickets are time-limited -- recreate the MirrorPeer on the hub to force
    a fresh ticket, and check for clock skew between the two clusters."
  fi
  if grep -q CONNECTION_FAILED "$SCP_BAD_FILE"; then
    if [ "$SUPPRESS_CONN" -eq 1 ]; then
      EXTRA="${EXTRA}
    CONNECTION_FAILED: this is the same problem as the more specific
    reachability/DNS finding elsewhere in this report -- see that instead."
    else
      EXTRA="${EXTRA}
    CONNECTION_FAILED: the spec.apiEndpoint above could not be reached.
    Check DNS resolution of that endpoint from this cluster, the
    Submariner gateway/connection status above, and whether a
    firewall/route is blocking the OCS provider gRPC port (default 50051)."
    fi
  fi
  BODY=$(sed 's/^/    /' "$SCP_BAD_FILE"; echo "$EXTRA")
  add_action "StorageClusterPeer(s) not Peered" "$BODY"
fi

if [ -s "$TEA_ERR_FILE" ]; then
  EXTRA=""
  if grep -qi "token audience" "$TEA_ERR_FILE" && [ "$KCS_7007854_SHOWN" -eq 0 ]; then
    EXTRA="${EXTRA}
    KCS: Encountered \"client is not within the token audience\" error during Token Exchange
         https://access.redhat.com/solutions/7007854"
    KCS_7007854_SHOWN=1
  fi
  BODY=$(sed 's/^/    /' "$TEA_ERR_FILE"; cat <<'EOF'

    This is the spoke-side agent that handles the actual MirrorPeer
    reconcile, S3/secret exchange, and onboarding-token HTTP calls on this
    cluster. If the StorageClusterPeer finding above shows CONNECTION_FAILED
    or INVALID_ONBOARDING_TICKET, these lines are usually the most direct
    evidence of which specific step failed and why.
EOF
)
  if [ -n "$EXTRA" ]; then
    BODY="$BODY
$EXTRA"
  fi
  add_action "token-exchange-agent pod logged matching errors" "$BODY"
fi

if [ -s "$SCP_ERR_FILE" ]; then
  EXTRA=""
  if grep -qi "token audience" "$SCP_ERR_FILE" && [ "$KCS_7007854_SHOWN" -eq 0 ]; then
    EXTRA="${EXTRA}
    KCS: Encountered \"client is not within the token audience\" error during Token Exchange
         https://access.redhat.com/solutions/7007854"
    KCS_7007854_SHOWN=1
  fi
  if grep -qi "blocklist" "$SCP_ERR_FILE"; then
    EXTRA="${EXTRA}
    Ceph mgr blocklisting can stop scheduled rbd-mirror snapshots from
    triggering even when StorageClusterPeer/MirrorPeer show healthy.
    Workaround: restart rook-ceph-mgr on the cluster where the images
    are primary:
      oc -n $NS scale deployments/rook-ceph-mgr-a --replicas=0
      oc -n $NS scale deployments/rook-ceph-mgr-a --replicas=1
    Docs: Regional-DR troubleshooting chapter
      https://docs.redhat.com/documentation/en-us/red_hat_openshift_data_foundation/4.18/html/configuring_openshift_data_foundation_disaster_recovery_for_openshift_workloads/index"
  fi
  BODY=$(sed 's/^/    /' "$SCP_ERR_FILE"; echo "$EXTRA")
  add_action "Matching errors found in ocs-operator/rook-ceph logs" "$BODY"
fi

if [ -s "$EP_BAD_FILE" ]; then
  BODY=$(sed 's/^/    /' "$EP_BAD_FILE"; cat <<'EOF'

    Inspect the object directly and compare against the peer's real, reachable
    hostname/route/LB IP and port:
      oc get storageclusterpeer <peer-name> -n <namespace> -o yaml
    spec.apiEndpoint should point to a hostname or IP the SOURCE cluster can
    actually resolve and route to -- not an internal-only address.
EOF
)
  add_action "StorageClusterPeer spec.apiEndpoint is missing or malformed" "$BODY"
fi

if [ -s "$NC_BAD_FILE" ] && [ ! -s "$LH_BAD_FILE" ]; then
  BODY=$(sed 's/^/    /' "$NC_BAD_FILE"; cat <<EOF

    A network boundary (firewall, cloud security group, or routing table) is
    likely dropping traffic between the clusters. Check:
      - Egress from THIS cluster to that host:port is allowed (see the
        egress policy finding below, if present).
      - Ingress on the TARGET cluster's firewall/security group for that
        port is open.
      - The Submariner gateway/connection status above, if traffic is meant
        to ride a Submariner tunnel.
    Re-test manually if needed:
      oc exec -it -n $NS <ocs-operator-pod> -- /bin/sh
      nc -zv <remote-host> <remote-port>
EOF
)
  add_action "TCP reachability test to spec.apiEndpoint failed" "$BODY"
fi
# NOTE: when LH_BAD_FILE is also non-empty, the TCP failure above is just a
# symptom of the DNS/Lighthouse problem reported there -- skip it here so
# the same root cause isn't listed twice.

if [ -s "$TLS_BAD_FILE" ]; then
  BODY=$(sed 's/^/    /' "$TLS_BAD_FILE"; cat <<'EOF'

    This usually means the onboarding/peering secret exchange completed with
    a certificate that's expired, self-signed and untrusted, or mismatched
    between the two clusters. Check the onboarding/peer secrets listed above
    for age and content, and confirm the provider server's serving
    certificate on the peer cluster is still valid.
EOF
)
  add_action "TLS/certificate errors found while connecting to the peer" "$BODY"
fi

if [ -s "$LH_BAD_FILE" ]; then
  BODY=$(sed 's/^/    /' "$LH_BAD_FILE"; cat <<'EOF'

    A .svc.clusterset.local hostname in apiEndpoint depends on Submariner's
    Lighthouse (Multicluster Services / MCS API) to resolve. If DNS lookups
    for that name fail (e.g. "Name or service not known"), this is the layer
    below TCP -- check, in this order:
      0. Do the CRDs even exist on THIS cluster and on the PEER?
           oc get crd serviceexports.multicluster.x-k8s.io serviceimports.multicluster.x-k8s.io
         Missing on either side means Submariner/Lighthouse (MCS API) isn't
         installed there -- nothing past this point will work until it is.
      1. On the PEER cluster: is the service actually exported?
           oc get serviceexports.multicluster.x-k8s.io -n <namespace>
         If missing, the service was never advertised into the clusterset.
      2. On THIS cluster: does the ServiceImport exist (see above)?
           oc get serviceimports.multicluster.x-k8s.io -n <namespace>
         If not, either step 1 failed, or the Submariner broker sync is broken.
      3. Is the Submariner connection between the two clusters Connected?
         (see the [COMMON] Submariner connectivity gateway/cluster output)
         Lighthouse depends on the same tunnel -- if it's down, nothing
         under clusterset.local will resolve.
      4. Are the submariner-lighthouse-agent and submariner-lighthouse-coredns
         pods (above) actually Running with no restarts?
      5. Does this cluster's CoreDNS forward the clusterset.local zone to
         Lighthouse (see the dns-default ConfigMap check above)?
EOF
)
  add_action "Submariner ServiceExport/ServiceImport/Lighthouse DNS problem detected" "$BODY"
fi

if [ -s "$EGRESS_BAD_FILE" ]; then
  BODY=$(sed 's/^/    /' "$EGRESS_BAD_FILE"; cat <<EOF

    These control whether THIS cluster is even allowed to send traffic to the
    peer's host:port -- a missing allow rule here looks identical to a
    network-level firewall drop. Check the printed rules above against the
    StorageClusterPeer's apiEndpoint:
      oc get networkpolicy -n $NS -o yaml
      oc get egressfirewall -n $NS -o yaml        # OVN-Kubernetes
      oc get egressnetworkpolicy -n $NS -o yaml    # legacy OpenShift SDN
    For a NetworkPolicy: confirm a rule's 'to:' selector/CIDR and 'ports:'
    cover the peer's IP/CIDR and port -- an Egress policyType with an empty
    egress list denies all egress by default.
    For EgressFirewall/EgressNetworkPolicy: rules are evaluated in order and
    the first match wins -- a 'Deny' rule ahead of (or in place of) an
    'Allow' for the peer's CIDR/dnsName/port will block this traffic even if
    a later rule would have allowed it.
EOF
)
  add_action "Egress-restricting policy object(s) found in -n $NS" "$BODY"
fi

if [ -n "${TEA_PODS:-}" ] && echo "${TEA_PODS:-}" | awk '{print $3}' | grep -qE '^[1-9][0-9]*$'; then
  BODY="    KCS: \"token-exchange-agent\" pod on managed cluster is unstable after upgrade to ODF 4.16.0
         https://access.redhat.com/solutions/7079562"
  add_action "token-exchange-agent pod shows restarts (see health table above)" "$BODY"
fi

echo "================================================================"
echo " ACTION ITEMS"
echo "================================================================"

if [ "${#ACTION_TITLES[@]}" -eq 0 ]; then
  cat <<EOF

  No issues found in the scanned window on this cluster.

  If peering is still failing:
    - Re-run this script against the OTHER cluster in the pair (hub vs.
      managed) -- a failure often only surfaces on one side.
    - Widen the log window: $0 $NS 24h
    - Check events cluster-wide for the peering objects:
        oc get events -A | grep -iE 'mirrorpeer|storageclusterpeer'
EOF
else
  echo
  echo "  ${#ACTION_TITLES[@]} issue(s) found, most fundamental first:"
  for i in "${!ACTION_TITLES[@]}"; do
    NUM=$((i + 1))
    echo
    echo "  ----------------------------------------------------------------"
    echo "  [$NUM] ${ACTION_TITLES[$i]}"
    echo "  ----------------------------------------------------------------"
    echo "${ACTION_BODIES[$i]}"
  done
fi

echo
echo "================================================================"
echo "Raw output saved in: $OUT_DIR"

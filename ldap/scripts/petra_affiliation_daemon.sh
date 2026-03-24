#!/usr/bin/env bash
set -u

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"

SYNC_SCRIPT="/opt/petra_iam_big_project/ldap/scripts/sync_petra_affiliation_hierarchy_fast.sh"
LOCK_FILE="/tmp/petra_affiliation_daemon.lock"
STATUS_FILE="/tmp/petra_affiliation_daemon.status"
LOG_FILE="/var/log/petra_affiliation.log"
INTERVAL="${INTERVAL:-10}"

STARTED_AT="$(date '+%F %T')"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

write_status() {
  cat > "$STATUS_FILE" <<EOF
PID=$$
STARTED_AT=$STARTED_AT
LAST_CYCLE_AT=$(date '+%F %T')
LAST_RESULT=$1
INTERVAL=$INTERVAL
EOF
}

if [[ ! -x "$SYNC_SCRIPT" ]]; then
  log "ERROR: sync script not found or not executable: $SYNC_SCRIPT"
  exit 1
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another daemon instance is already running. Exiting."
  exit 0
fi

log "Petra affiliation daemon started pid=$$ interval=${INTERVAL}s"
write_status "daemon_started"

while true; do
  cycle_start=$(date +%s)

  result="$(
    LDAP_URI="$LDAP_URI" \
    LDAP_BIND_DN="$LDAP_BIND_DN" \
    LDAP_BIND_PW="$LDAP_BIND_PW" \
    "$SYNC_SCRIPT" 2>&1
  )"
  rc=$?

  cycle_end=$(date +%s)
  duration=$((cycle_end - cycle_start))

  if [[ $rc -eq 0 ]]; then
    log "cycle_ok duration=${duration}s $result"
    write_status "ok duration=${duration}s $result"
  else
    log "cycle_failed duration=${duration}s $result"
    write_status "failed duration=${duration}s"
  fi

  sleep "$INTERVAL"
done

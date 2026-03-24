#!/usr/bin/env bash
set -u

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"

SYNC_SCRIPT="/opt/petra_iam_big_project/ldap/scripts/sync_petra_affiliation_hierarchy_fast.sh"
LOCK_FILE="/tmp/petra_affiliation_every_10s.lock"
LOG_FILE="/var/log/petra_affiliation.log"

log() {
  echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

if [[ ! -x "$SYNC_SCRIPT" ]]; then
  log "ERROR: sync script not executable: $SYNC_SCRIPT"
  exit 1
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "SKIP: previous 10s runner still active"
  exit 0
fi

for i in 1 2 3 4 5 6; do
  start_ts=$(date +%s)

  result="$(
    LDAP_URI="$LDAP_URI" \
    LDAP_BIND_DN="$LDAP_BIND_DN" \
    LDAP_BIND_PW="$LDAP_BIND_PW" \
    "$SYNC_SCRIPT" 2>&1
  )"
  rc=$?

  end_ts=$(date +%s)
  duration=$((end_ts - start_ts))

  if [[ $rc -eq 0 ]]; then
    log "RUN#$i ok duration=${duration}s $result"
  else
    log "RUN#$i failed duration=${duration}s $result"
  fi

  if [[ "$i" -lt 6 ]]; then
    sleep 10
  fi
done


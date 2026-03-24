#!/usr/bin/env bash
set -u

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"

GROUPS_BASE="${GROUPS_BASE:-ou=groups,dc=petra,dc=ac,dc=id}"
APPS_BASE="${APPS_BASE:-ou=apps,ou=groups,dc=petra,dc=ac,dc=id}"

LOCK_FILE="/tmp/reconcile_app_groups_every_10s.lock"
LOG_FILE="/var/log/reconcile_app_groups.log"

log() {
  echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: command not found: $1"
    exit 1
  }
}

ensure_apps_base_exists() {
  ldapsearch -LLL -x -o ldif-wrap=no \
    -H "$LDAP_URI" \
    -D "$LDAP_BIND_DN" \
    -w "$LDAP_BIND_PW" \
    -b "$APPS_BASE" \
    -s base "(objectClass=organizationalUnit)" dn >/dev/null 2>&1

  if [[ $? -ne 0 ]]; then
    log "ERROR: APPS_BASE not found: $APPS_BASE"
    exit 1
  fi
}

move_group_if_needed() {
  local dn="$1"
  local cn_value="$2"
  local new_rdn="cn=${cn_value}"

  if [[ "$dn" == *",$APPS_BASE" ]]; then
    log "SKIP: already under ou=apps -> $dn"
    return 0
  fi

  log "MOVE: $dn -> $new_rdn,$APPS_BASE"

  result="$(
    ldapmodrdn -x -r \
      -H "$LDAP_URI" \
      -D "$LDAP_BIND_DN" \
      -w "$LDAP_BIND_PW" \
      "$dn" \
      "$new_rdn" \
      -s "$APPS_BASE" 2>&1
  )"
  rc=$?

  if [[ $rc -eq 0 ]]; then
    log "DONE: moved $dn -> $new_rdn,$APPS_BASE"
  else
    log "ERROR: failed moving $dn rc=$rc output=$result"
  fi
}

scan_and_reconcile_once() {
  local results dn cn_value

  results="$(
    ldapsearch -LLL -x -o ldif-wrap=no \
      -H "$LDAP_URI" \
      -D "$LDAP_BIND_DN" \
      -w "$LDAP_BIND_PW" \
      -b "$GROUPS_BASE" \
      "(&(objectClass=groupOfNames)(cn=app-*))" \
      dn cn 2>/dev/null
  )"

  if [[ -z "${results// }" ]]; then
    log "INFO: no app-* groups found"
    return 0
  fi

  dn=""
  cn_value=""

  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      if [[ -n "$dn" && -n "$cn_value" ]]; then
        move_group_if_needed "$dn" "$cn_value"
      fi
      dn=""
      cn_value=""
      continue
    fi

    if [[ "$line" == dn:\ * ]]; then
      dn="${line#dn: }"
    elif [[ "$line" == cn:\ * ]]; then
      cn_value="${line#cn: }"
    fi
  done <<< "$results"

  if [[ -n "$dn" && -n "$cn_value" ]]; then
    move_group_if_needed "$dn" "$cn_value"
  fi
}

run_once_with_log() {
  start_ts=$(date +%s)

  scan_and_reconcile_once
  rc=$?

  end_ts=$(date +%s)
  duration=$((end_ts - start_ts))

  if [[ $rc -eq 0 ]]; then
    log "RUN ok duration=${duration}s"
  else
    log "RUN failed duration=${duration}s"
  fi
}

main() {
  require_cmd ldapsearch
  require_cmd ldapmodrdn
  ensure_apps_base_exists

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "SKIP: previous runner still active"
    exit 0
  fi

  for i in 1 2 3 4 5 6; do
    run_once_with_log
    if [[ "$i" -lt 6 ]]; then
      sleep 10
    fi
  done
}

main "$@"

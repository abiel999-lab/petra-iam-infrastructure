#!/usr/bin/env bash
set -Eeuo pipefail

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"

GROUPS_BASE="${GROUPS_BASE:-ou=groups,dc=petra,dc=ac,dc=id}"

usage() {
  cat <<EOF
Usage:
  $0 <group-cn> <target-ou>

Example:
  $0 app-web apps
  $0 role-student roles
  $0 unit-fakultas-teknik units

Environment variables (optional):
  LDAP_URI
  LDAP_BIND_DN
  LDAP_BIND_PW
  GROUPS_BASE
EOF
}

log() {
  echo "[$(date '+%F %T')] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: command not found: $1" >&2
    exit 1
  }
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

GROUP_CN="$1"
TARGET_OU="$2"
TARGET_BASE="ou=${TARGET_OU},${GROUPS_BASE}"

require_cmd ldapsearch
require_cmd ldapmodrdn

log "Checking target OU: ${TARGET_BASE}"
if ! ldapsearch -LLL -x -o ldif-wrap=no \
  -H "$LDAP_URI" \
  -D "$LDAP_BIND_DN" \
  -w "$LDAP_BIND_PW" \
  -b "$TARGET_BASE" \
  -s base "(objectClass=organizationalUnit)" dn >/dev/null 2>&1; then
  echo "ERROR: target OU not found: ${TARGET_BASE}" >&2
  exit 1
fi

log "Searching group cn=${GROUP_CN} under ${GROUPS_BASE}"
SEARCH_RESULT="$(
  ldapsearch -LLL -x -o ldif-wrap=no \
    -H "$LDAP_URI" \
    -D "$LDAP_BIND_DN" \
    -w "$LDAP_BIND_PW" \
    -b "$GROUPS_BASE" \
    "(&(objectClass=groupOfNames)(cn=${GROUP_CN}))" \
    dn cn
)"

MATCH_COUNT="$(printf '%s\n' "$SEARCH_RESULT" | grep -c '^dn: ' || true)"

if [[ "$MATCH_COUNT" -eq 0 ]]; then
  echo "ERROR: group cn=${GROUP_CN} not found under ${GROUPS_BASE}" >&2
  exit 1
fi

if [[ "$MATCH_COUNT" -gt 1 ]]; then
  echo "ERROR: more than one entry found for cn=${GROUP_CN}. Please clean duplicates first." >&2
  printf '%s\n' "$SEARCH_RESULT"
  exit 1
fi

CURRENT_DN="$(printf '%s\n' "$SEARCH_RESULT" | awk -F': ' '/^dn: /{print $2}')"

if [[ "$CURRENT_DN" == *",${TARGET_BASE}" ]]; then
  log "SKIP: already in target OU -> ${CURRENT_DN}"
  exit 0
fi

log "Moving:"
log "  FROM: ${CURRENT_DN}"
log "  TO  : cn=${GROUP_CN},${TARGET_BASE}"

ldapmodrdn -x -r \
  -H "$LDAP_URI" \
  -D "$LDAP_BIND_DN" \
  -w "$LDAP_BIND_PW" \
  "$CURRENT_DN" \
  "cn=${GROUP_CN}" \
  -s "$TARGET_BASE"

log "DONE: cn=${GROUP_CN} moved to ${TARGET_BASE}"

#!/usr/bin/env bash
set -euo pipefail

# =========================
# Usage:
#   grant_app_access.sh u-00020030 app-mypetra
# =========================

USER_UID="${1:?Usage: grant_app_access.sh <uid> <app-group-cn>  (contoh: u-00020030 app-mypetra)}"
APP_CN="${2:?Usage: grant_app_access.sh <uid> <app-group-cn>  (contoh: u-00020030 app-mypetra)}"

LDAP_URL="${LDAP_URL:-ldap://127.0.0.1:389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"
PEOPLE_BASE="${PEOPLE_BASE:-ou=people,dc=petra,dc=ac,dc=id}"
APPS_BASE="${APPS_BASE:-ou=apps,ou=groups,dc=petra,dc=ac,dc=id}"

# 1) resolve user DN
USER_DN="$(ldapsearch -x -H "$LDAP_URL" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PW" \
  -b "$PEOPLE_BASE" "(uid=${USER_UID})" dn -LLL \
  | awk -F': ' '/^dn: /{print $2; exit}')"

if [[ -z "${USER_DN:-}" ]]; then
  echo "[ERR] User tidak ditemukan: uid=${USER_UID} di base ${PEOPLE_BASE}"
  exit 1
fi

# 2) resolve group DN
GROUP_DN="$(ldapsearch -x -H "$LDAP_URL" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PW" \
  -b "$APPS_BASE" "(cn=${APP_CN})" dn -LLL \
  | awk -F': ' '/^dn: /{print $2; exit}')"

if [[ -z "${GROUP_DN:-}" ]]; then
  echo "[ERR] App group tidak ditemukan: cn=${APP_CN} di base ${APPS_BASE}"
  exit 1
fi

# 3) check if already member
ALREADY="$(ldapsearch -x -H "$LDAP_URL" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PW" \
  -b "$GROUP_DN" "(objectClass=*)" member -LLL \
  | awk -F': ' '/^member: /{print $2}' \
  | grep -Fx "$USER_DN" || true)"

if [[ -n "${ALREADY:-}" ]]; then
  echo "[OK] Sudah member: ${USER_UID} -> ${APP_CN}"
  echo "     userDN : $USER_DN"
  echo "     groupDN: $GROUP_DN"
  exit 0
fi

# 4) add member
ldapmodify -x -H "$LDAP_URL" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PW" <<LDIF
dn: ${GROUP_DN}
changetype: modify
add: member
member: ${USER_DN}
LDIF

echo "[OK] GRANTED: ${USER_UID} -> ${APP_CN}"
echo "     userDN : $USER_DN"
echo "     groupDN: $GROUP_DN"

#!/usr/bin/env bash
set -euo pipefail

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <uid> <role>"
  echo "Example: $0 ani0004 role-student"
  exit 1
fi

UID_VALUE="$1"
TARGET_ROLE="$2"

BASE_DN="dc=petra,dc=ac,dc=id"
PEOPLE_DN="ou=people,${BASE_DN}"
ROLES_DN="ou=roles,ou=groups,${BASE_DN}"
USER_DN="uid=${UID_VALUE},${PEOPLE_DN}"

VALID_ROLES=(
  "role-student"
  "role-staff"
  "role-alumni"
  "role-external"
)

is_valid_role=false
for r in "${VALID_ROLES[@]}"; do
  if [[ "$TARGET_ROLE" == "$r" ]]; then
    is_valid_role=true
    break
  fi
done

if [[ "$UID_VALUE" != ani* ]]; then
  echo "ERROR: This script is restricted to ani* users only."
  exit 1
fi

if [[ "$is_valid_role" != true ]]; then
  echo "ERROR: Invalid role: $TARGET_ROLE"
  echo "Allowed roles: ${VALID_ROLES[*]}"
  exit 1
fi

user_exists="$(
  ldapsearch -LLL -x -o ldif-wrap=no -H "$LDAP_URI" \
    -D "$LDAP_BIND_DN" \
    -w "$LDAP_BIND_PW" \
    -b "$USER_DN" \
    -s base dn 2>/dev/null | grep '^dn:' || true
)"

if [[ -z "$user_exists" ]]; then
  echo "ERROR: User not found: $USER_DN"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REMOVE_LDIF="${TMP_DIR}/remove_roles.ldif"
ADD_LDIF="${TMP_DIR}/add_target_role.ldif"
AFF_LDIF="${TMP_DIR}/set_affiliation.ldif"

: > "$REMOVE_LDIF"
: > "$ADD_LDIF"
: > "$AFF_LDIF"

echo "INFO: Removing ${USER_DN} from all role groups first..."

for role in "${VALID_ROLES[@]}"; do
  role_has_user="$(
    ldapsearch -LLL -x -o ldif-wrap=no -H "$LDAP_URI" \
      -D "$LDAP_BIND_DN" \
      -w "$LDAP_BIND_PW" \
      -b "cn=${role},${ROLES_DN}" \
      -s base member 2>/dev/null \
      | grep -F "member: ${USER_DN}" || true
  )"

  if [[ -n "$role_has_user" ]]; then
    {
      echo "dn: cn=${role},${ROLES_DN}"
      echo "changetype: modify"
      echo "delete: member"
      echo "member: ${USER_DN}"
      echo "-"
      echo ""
    } >> "$REMOVE_LDIF"
  fi
done

if [[ -s "$REMOVE_LDIF" ]]; then
  ldapmodify -x -H "$LDAP_URI" \
    -D "$LDAP_BIND_DN" \
    -w "$LDAP_BIND_PW" \
    -f "$REMOVE_LDIF"
fi

echo "INFO: Adding ${USER_DN} to ${TARGET_ROLE}..."

{
  echo "dn: cn=${TARGET_ROLE},${ROLES_DN}"
  echo "changetype: modify"
  echo "add: member"
  echo "member: ${USER_DN}"
  echo "-"
  echo ""
} > "$ADD_LDIF"

ldapmodify -x -H "$LDAP_URI" \
  -D "$LDAP_BIND_DN" \
  -w "$LDAP_BIND_PW" \
  -f "$ADD_LDIF"

echo "INFO: Updating petraAffiliation to ${TARGET_ROLE}..."

{
  echo "dn: ${USER_DN}"
  echo "changetype: modify"
  echo "replace: petraAffiliation"
  echo "petraAffiliation: ${TARGET_ROLE}"
  echo "-"
  echo ""
} > "$AFF_LDIF"

ldapmodify -x -H "$LDAP_URI" \
  -D "$LDAP_BIND_DN" \
  -w "$LDAP_BIND_PW" \
  -f "$AFF_LDIF"

echo "DONE: ${UID_VALUE} moved to ${TARGET_ROLE}"
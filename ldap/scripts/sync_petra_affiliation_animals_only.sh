#!/usr/bin/env bash
set -euo pipefail

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"

BASE_DN="dc=petra,dc=ac,dc=id"
PEOPLE_DN="ou=people,${BASE_DN}"
ROLES_DN="ou=roles,ou=groups,${BASE_DN}"

ROLE_PRIORITY=(
  "role-student"
  "role-staff"
  "role-alumni"
  "role-external"
)

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROLE_FILE="${TMP_DIR}/role_members.tsv"
USERS_FILE="${TMP_DIR}/ani_users.txt"
LDIF_FILE="${TMP_DIR}/sync_affiliation_animals.ldif"

: > "$ROLE_FILE"
: > "$USERS_FILE"
: > "$LDIF_FILE"

is_animals_test_user() {
  local user_dn="$1"
  [[ "$user_dn" =~ ^uid=ani[0-9]+,ou=people,dc=petra,dc=ac,dc=id$ ]]
}

fetch_members_for_role() {
  local role_cn="$1"

  ldapsearch -LLL -x -o ldif-wrap=no -H "$LDAP_URI" \
    -D "$LDAP_BIND_DN" \
    -w "$LDAP_BIND_PW" \
    -b "cn=${role_cn},${ROLES_DN}" \
    -s base member 2>/dev/null \
    | awk -v role="$role_cn" '
        /^member: / {
          sub(/^member: /, "", $0)
          print $0 "\t" role
        }
      '
}

fetch_all_ani_users() {
  ldapsearch -LLL -x -o ldif-wrap=no -H "$LDAP_URI" \
    -D "$LDAP_BIND_DN" \
    -w "$LDAP_BIND_PW" \
    -b "$PEOPLE_DN" \
    "(uid=ani*)" dn 2>/dev/null \
    | awk '/^dn: /{
        sub(/^dn: /, "", $0)
        print
      }'
}

for role_cn in "${ROLE_PRIORITY[@]}"; do
  fetch_members_for_role "$role_cn" >> "$ROLE_FILE"
done

fetch_all_ani_users > "$USERS_FILE"

if [[ ! -s "$USERS_FILE" ]]; then
  echo "No ani* users found."
  exit 0
fi

declare -A FIRST_ROLE
declare -A ROLE_COUNT
declare -A ROLE_LIST

if [[ -s "$ROLE_FILE" ]]; then
  while IFS=$'\t' read -r user_dn role_cn; do
    [[ -z "${user_dn:-}" ]] && continue
    is_animals_test_user "$user_dn" || continue

    if [[ -z "${FIRST_ROLE[$user_dn]+x}" ]]; then
      FIRST_ROLE["$user_dn"]="$role_cn"
      ROLE_COUNT["$user_dn"]=1
      ROLE_LIST["$user_dn"]="$role_cn"
    else
      ROLE_COUNT["$user_dn"]=$(( ROLE_COUNT["$user_dn"] + 1 ))
      ROLE_LIST["$user_dn"]="${ROLE_LIST[$user_dn]},$role_cn"
    fi
  done < "$ROLE_FILE"
fi

while IFS= read -r user_dn; do
  [[ -z "${user_dn:-}" ]] && continue
  is_animals_test_user "$user_dn" || continue

  desired_affiliation="none"

  if [[ -n "${FIRST_ROLE[$user_dn]+x}" ]]; then
    desired_affiliation="${FIRST_ROLE[$user_dn]}"
  fi

  if [[ -n "${ROLE_COUNT[$user_dn]+x}" ]] && [[ "${ROLE_COUNT[$user_dn]}" -gt 1 ]]; then
    echo "WARNING: multiple roles detected for ${user_dn} -> ${ROLE_LIST[$user_dn]}"
    echo "WARNING: sync will keep ${desired_affiliation} based on priority"
  fi

  current_value="$(
    ldapsearch -LLL -x -o ldif-wrap=no -H "$LDAP_URI" \
      -D "$LDAP_BIND_DN" \
      -w "$LDAP_BIND_PW" \
      -b "$user_dn" \
      -s base petraAffiliation 2>/dev/null \
      | awk '/^petraAffiliation: /{
          sub(/^petraAffiliation: /, "", $0)
          print
          exit
        }'
  )"

  if [[ "$current_value" != "$desired_affiliation" ]]; then
    {
      echo "dn: ${user_dn}"
      echo "changetype: modify"
      echo "replace: petraAffiliation"
      echo "petraAffiliation: ${desired_affiliation}"
      echo "-"
      echo ""
    } >> "$LDIF_FILE"

    echo "SYNC: ${user_dn} -> petraAffiliation=${desired_affiliation}"
  fi
done < "$USERS_FILE"

if [[ ! -s "$LDIF_FILE" ]]; then
  echo "No changes needed for ani* users."
  exit 0
fi

ldapmodify -x -H "$LDAP_URI" \
  -D "$LDAP_BIND_DN" \
  -w "$LDAP_BIND_PW" \
  -f "$LDIF_FILE"

echo "DONE: petraAffiliation synchronized for ani* users only."
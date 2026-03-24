#!/usr/bin/env bash
set -euo pipefail

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"

BASE_DN="dc=petra,dc=ac,dc=id"
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
LDIF_FILE="${TMP_DIR}/enforce_single_role.ldif"

: > "$ROLE_FILE"
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

for role_cn in "${ROLE_PRIORITY[@]}"; do
  fetch_members_for_role "$role_cn" >> "$ROLE_FILE"
done

if [[ ! -s "$ROLE_FILE" ]]; then
  echo "No role memberships found."
  exit 0
fi

awk -F '\t' '
{
  user_dn=$1
  role=$2

  if (!(user_dn in first_role)) {
    first_role[user_dn]=role
    role_list[user_dn]=role
    count[user_dn]=1
  } else {
    role_list[user_dn]=role_list[user_dn] "," role
    count[user_dn]++
  }
}
END {
  for (u in first_role) {
    printf "%s\t%s\t%s\t%d\n", u, first_role[u], role_list[u], count[u]
  }
}
' "$ROLE_FILE" | while IFS=$'\t' read -r user_dn keep_role all_roles role_count; do
  if ! is_animals_test_user "$user_dn"; then
    continue
  fi

  if [[ "$role_count" -gt 1 ]]; then
    echo "STRICT: ${user_dn} has multiple roles -> ${all_roles}"
    echo "STRICT: keep ${keep_role}, remove others"
  fi

  IFS=',' read -r -a roles_arr <<< "$all_roles"

  for role in "${roles_arr[@]}"; do
    if [[ "$role" != "$keep_role" ]]; then
      {
        echo "dn: cn=${role},${ROLES_DN}"
        echo "changetype: modify"
        echo "delete: member"
        echo "member: ${user_dn}"
        echo "-"
        echo ""
      } >> "$LDIF_FILE"
    fi
  done

  current_aff="$(
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

  if [[ "$current_aff" != "$keep_role" ]]; then
    {
      echo "dn: ${user_dn}"
      echo "changetype: modify"
      echo "replace: petraAffiliation"
      echo "petraAffiliation: ${keep_role}"
      echo "-"
      echo ""
    } >> "$LDIF_FILE"
  fi
done

if [[ ! -s "$LDIF_FILE" ]]; then
  echo "No strict enforcement changes needed for ani* users."
  exit 0
fi

ldapmodify -x -H "$LDAP_URI" \
  -D "$LDAP_BIND_DN" \
  -w "$LDAP_BIND_PW" \
  -f "$LDIF_FILE"

echo "DONE: strict single-role enforcement applied for ani* users."
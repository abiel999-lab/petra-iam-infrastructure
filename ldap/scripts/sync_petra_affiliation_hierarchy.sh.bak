#!/usr/bin/env bash
set -u

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"

BASE_DN="dc=petra,dc=ac,dc=id"
PEOPLE_DN="ou=people,$BASE_DN"
ROLES_BASE_DN="ou=roles,ou=groups,$BASE_DN"

ROLE_ORDER=("staff" "student" "alumni" "external")

TMP_DIR="/tmp/petra_aff_sync"
mkdir -p "$TMP_DIR"

ROLE_MEMBERS_FILE="$TMP_DIR/role_members.txt"
ALL_USERS_FILE="$TMP_DIR/all_users.txt"
LDIF_FILE="$TMP_DIR/sync_roles.ldif"

: > "$ROLE_MEMBERS_FILE"
: > "$ALL_USERS_FILE"
: > "$LDIF_FILE"

log() {
  echo "[$(date '+%F %T')] $*"
}

contains_word() {
  local word="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$word" ]]; then
      return 0
    fi
  done
  return 1
}

ldapsearch -LLL -x \
  -H "$LDAP_URI" \
  -D "$LDAP_BIND_DN" \
  -w "$LDAP_BIND_PW" \
  -b "$PEOPLE_DN" \
  "(uid=*)" dn | awk '/^dn: /{print substr($0,5)}' > "$ALL_USERS_FILE"

for role in "${ROLE_ORDER[@]}"; do
  ldapsearch -LLL -x \
    -H "$LDAP_URI" \
    -D "$LDAP_BIND_DN" \
    -w "$LDAP_BIND_PW" \
    -b "cn=role-$role,$ROLES_BASE_DN" \
    "(objectClass=*)" member 2>/dev/null \
  | awk -v r="$role" '/^member: /{print substr($0,9) "|" r}' >> "$ROLE_MEMBERS_FILE"
done

while IFS= read -r user_dn; do
  [[ -z "$user_dn" ]] && continue

  user_roles=()
  while IFS='|' read -r member_dn member_role; do
    [[ -z "$member_dn" || -z "$member_role" ]] && continue
    if [[ "$member_dn" == "$user_dn" ]]; then
      if ! contains_word "$member_role" "${user_roles[@]:-}"; then
        user_roles+=("$member_role")
      fi
    fi
  done < "$ROLE_MEMBERS_FILE"

  primary="none"
  alternate_roles=()

  if [[ ${#user_roles[@]} -gt 0 ]]; then
    for ordered_role in "${ROLE_ORDER[@]}"; do
      if contains_word "$ordered_role" "${user_roles[@]}"; then
        primary="$ordered_role"
        break
      fi
    done

    for ordered_role in "${ROLE_ORDER[@]}"; do
      if contains_word "$ordered_role" "${user_roles[@]}" && [[ "$ordered_role" != "$primary" ]]; then
        alternate_roles+=("$ordered_role")
      fi
    done
  fi

  current_primary="$(
    ldapsearch -LLL -x \
      -H "$LDAP_URI" \
      -D "$LDAP_BIND_DN" \
      -w "$LDAP_BIND_PW" \
      -b "$user_dn" \
      "(objectClass=*)" petraAffiliation \
    | awk -F': ' '/^petraAffiliation: /{print $2; exit}'
  )"

  current_alt="$(
    ldapsearch -LLL -x \
      -H "$LDAP_URI" \
      -D "$LDAP_BIND_DN" \
      -w "$LDAP_BIND_PW" \
      -b "$user_dn" \
      "(objectClass=*)" petraAlternateAffiliation \
    | awk -F': ' '/^petraAlternateAffiliation: /{print $2}'
  )"

  need_update=0

  if [[ "$current_primary" != "$primary" ]]; then
    need_update=1
  fi

  desired_alt_joined="$(printf '%s\n' "${alternate_roles[@]:-}" | sed '/^$/d' | sort -u)"
  current_alt_joined="$(printf '%s\n' "$current_alt" | sed '/^$/d' | sort -u)"

  if [[ "$desired_alt_joined" != "$current_alt_joined" ]]; then
    need_update=1
  fi

  if [[ "$need_update" -eq 1 ]]; then
    {
      echo "dn: $user_dn"
      echo "changetype: modify"
      echo "replace: petraAffiliation"
      echo "petraAffiliation: $primary"
      echo "-"
      echo "replace: petraAlternateAffiliation"
      for alt in "${alternate_roles[@]:-}"; do
        [[ -n "$alt" && "$alt" != "$primary" ]] && echo "petraAlternateAffiliation: $alt"
      done
      echo
    } >> "$LDIF_FILE"
  fi

done < "$ALL_USERS_FILE"

if [[ -s "$LDIF_FILE" ]]; then
  log "Applying affiliation sync changes..."
  ldapmodify -x \
    -H "$LDAP_URI" \
    -D "$LDAP_BIND_DN" \
    -w "$LDAP_BIND_PW" \
    -f "$LDIF_FILE"
else
  log "No affiliation changes needed."
fi

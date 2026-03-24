#!/usr/bin/env bash
set -u

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"

BASE_DN="dc=petra,dc=ac,dc=id"
PEOPLE_DN="ou=people,$BASE_DN"
ROLES_BASE_DN="ou=roles,ou=groups,$BASE_DN"

ROLE_ORDER=("staff" "student" "alumni" "external")

TMP_DIR="/tmp/petra_aff_sync_fast"
mkdir -p "$TMP_DIR"

USERS_FILE="$TMP_DIR/users.ldif"
ROLES_FILE="$TMP_DIR/roles.ldif"
LDIF_FILE="$TMP_DIR/changes.ldif"

: > "$USERS_FILE"
: > "$ROLES_FILE"
: > "$LDIF_FILE"

contains_word() {
  local word="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$word" ]] && return 0
  done
  return 1
}

# 1. Bulk read semua user + attribute sekarang
ldapsearch -LLL -x \
  -H "$LDAP_URI" \
  -D "$LDAP_BIND_DN" \
  -w "$LDAP_BIND_PW" \
  -b "$PEOPLE_DN" \
  "(uid=*)" dn petraAffiliation petraAlternateAffiliation > "$USERS_FILE"

# 2. Bulk read semua role group
ldapsearch -LLL -x \
  -H "$LDAP_URI" \
  -D "$LDAP_BIND_DN" \
  -w "$LDAP_BIND_PW" \
  -b "$ROLES_BASE_DN" \
  "(cn=role-*)" dn cn member > "$ROLES_FILE"

# 3. Parse role membership -> associative array
declare -A USER_ROLES

current_role=""
while IFS= read -r line; do
  case "$line" in
    cn:\ role-*)
      current_role="${line#cn: role-}"
      ;;
    member:\ *)
      member_dn="${line#member: }"
      if [[ -n "$current_role" ]]; then
        USER_ROLES["$member_dn"]+="$current_role "
      fi
      ;;
    "")
      current_role=""
      ;;
  esac
done < "$ROLES_FILE"

# 4. Parse user file per entry
current_dn=""
current_primary=""
current_alts=()

flush_user() {
  [[ -z "$current_dn" ]] && return 0

  desired_roles_raw="${USER_ROLES[$current_dn]:-}"
  desired_roles=()
  for role in ${desired_roles_raw:-}; do
    if ! contains_word "$role" "${desired_roles[@]:-}"; then
      desired_roles+=("$role")
    fi
  done

  desired_primary="none"
  desired_alts=()

  if [[ ${#desired_roles[@]} -gt 0 ]]; then
    for ordered_role in "${ROLE_ORDER[@]}"; do
      if contains_word "$ordered_role" "${desired_roles[@]}"; then
        desired_primary="$ordered_role"
        break
      fi
    done

    for ordered_role in "${ROLE_ORDER[@]}"; do
      if contains_word "$ordered_role" "${desired_roles[@]}" && [[ "$ordered_role" != "$desired_primary" ]]; then
        desired_alts+=("$ordered_role")
      fi
    done
  fi

  desired_alt_joined="$(printf '%s\n' "${desired_alts[@]:-}" | sed '/^$/d' | sort -u)"
  current_alt_joined="$(printf '%s\n' "${current_alts[@]:-}" | sed '/^$/d' | sort -u)"

  if [[ "$current_primary" != "$desired_primary" || "$current_alt_joined" != "$desired_alt_joined" ]]; then
    {
      echo "dn: $current_dn"
      echo "changetype: modify"
      echo "replace: petraAffiliation"
      echo "petraAffiliation: $desired_primary"
      echo "-"
      echo "replace: petraAlternateAffiliation"
      for alt in "${desired_alts[@]:-}"; do
        [[ -n "$alt" && "$alt" != "$desired_primary" ]] && echo "petraAlternateAffiliation: $alt"
      done
      echo
    } >> "$LDIF_FILE"
  fi
}

while IFS= read -r line; do
  case "$line" in
    dn:\ *)
      flush_user
      current_dn="${line#dn: }"
      current_primary=""
      current_alts=()
      ;;
    petraAffiliation:\ *)
      current_primary="${line#petraAffiliation: }"
      ;;
    petraAlternateAffiliation:\ *)
      current_alts+=("${line#petraAlternateAffiliation: }")
      ;;
    "")
      :
      ;;
  esac
done < "$USERS_FILE"

flush_user

changed_entries=$(grep -c '^dn: ' "$LDIF_FILE" 2>/dev/null || true)
users_scanned=$(grep -c '^dn: ' "$USERS_FILE" 2>/dev/null || true)
groups_scanned=$(grep -c '^cn: role-' "$ROLES_FILE" 2>/dev/null || true)

if [[ -s "$LDIF_FILE" ]]; then
  ldapmodify -x \
    -H "$LDAP_URI" \
    -D "$LDAP_BIND_DN" \
    -w "$LDAP_BIND_PW" \
    -f "$LDIF_FILE" >/dev/null
fi

echo "users_scanned=$users_scanned groups_scanned=$groups_scanned changed_entries=$changed_entries"

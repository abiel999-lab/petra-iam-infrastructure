#!/usr/bin/env bash
set -Eeuo pipefail

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
LDAP_BIND_PW="${LDAP_BIND_PW:-SeongJinWoo999!}"

SCRIPT_DIR="/opt/petra_iam_big_project/ldap/scripts"
MOVE_SCRIPT="${SCRIPT_DIR}/move_group_to_ou.sh"

if [[ ! -x "$MOVE_SCRIPT" ]]; then
  echo "ERROR: move script not found or not executable: $MOVE_SCRIPT" >&2
  exit 1
fi

# Format: "group-cn target-ou"
MAPS=(
  "app-web apps"
  "app-mobile apps"
  "app-wifi-dot1x apps"

  "role-alumni roles"
  "role-external roles"
  "role-staff roles"
  "role-student roles"
)

for item in "${MAPS[@]}"; do
  group_cn="$(awk '{print $1}' <<< "$item")"
  target_ou="$(awk '{print $2}' <<< "$item")"

  echo "============================================================"
  echo "MOVE: ${group_cn} -> ou=${target_ou}"
  LDAP_URI="$LDAP_URI" \
  LDAP_BIND_DN="$LDAP_BIND_DN" \
  LDAP_BIND_PW="$LDAP_BIND_PW" \
  "$MOVE_SCRIPT" "$group_cn" "$target_ou"
done

echo "All mappings processed."

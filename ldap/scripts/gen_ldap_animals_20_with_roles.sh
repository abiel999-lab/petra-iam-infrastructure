#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Petra IAM - Generate 20 LDAP users under ou=people only
# and assign each user to exactly one role group.
#
# Outputs:
#   1. users LDIF
#   2. role-membership LDIF
#   3. revert LDIF
#
# petraAffiliation is set equal to role cn:
#   role-student / role-staff / role-alumni / role-external
# =========================================================

# -------------------------
# 1) Defaults & args
# -------------------------
SEED="20260316"
PASSWORD="SeongJinWoo999!"
OUT_USERS="ldif/03-users-animals-20.generated.ldif"
OUT_GROUPS="ldif/04-role-memberships-animals-20.generated.ldif"
REVERT_OUT="ldif/05-revert-animals-20.generated.ldif"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed) SEED="${2:-}"; shift 2;;
    --password) PASSWORD="${2:-}"; shift 2;;
    --out-users) OUT_USERS="${2:-}"; shift 2;;
    --out-groups) OUT_GROUPS="${2:-}"; shift 2;;
    --revert-out) REVERT_OUT="${2:-}"; shift 2;;
    -h|--help)
      sed -n '1,220p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl not found." >&2
  exit 1
fi

BASE_DN="dc=petra,dc=ac,dc=id"
PEOPLE_DN="ou=people,${BASE_DN}"
ROLES_DN="ou=roles,ou=groups,${BASE_DN}"

MAIL_SUBDOMAINS=( "john" "peter" "petra" )
ROLE_CNS=( "role-student" "role-staff" "role-alumni" "role-external" )
STATUSES=( "active" "active" "active" "active" "active" "active" "active" "disabled" "suspended" )

NIK_REGION_CODES=(
  "357801" "351501" "351401" "327301" "317401"
  "317301" "337401" "347101" "517101" "127101"
)

ANIMAL_NAMES=(
  "Kucing Anggora"
  "Anjing Golden"
  "Harimau Sumatra"
  "Gajah Asia"
  "Singa Afrika"
  "Panda Raksasa"
  "Koala Lucu"
  "Kelinci Putih"
  "Rusa Timor"
  "Burung Elang"
  "Lumba Lumba"
  "Paus Biru"
  "Ikan Koi"
  "Kuda Laut"
  "Kura Kura"
  "Buaya Muara"
  "Ular Piton"
  "Katak Pohon"
  "Serigala Abu"
  "Beruang Madu"
)

if [[ "${#ANIMAL_NAMES[@]}" -ne 20 ]]; then
  echo "ERROR: ANIMAL_NAMES must contain exactly 20 items." >&2
  exit 1
fi

# -------------------------
# 2) Deterministic RNG
# -------------------------
RSTATE=$(( (SEED + 0) & 0x7fffffff ))

rand_u31() {
  RSTATE=$(( (1103515245 * RSTATE + 12345) & 0x7fffffff ))
  echo "$RSTATE"
}

rand_range() {
  local min="$1" max="$2"
  local r
  r="$(rand_u31)"
  echo $(( min + (r % (max - min + 1)) ))
}

rand_choice() {
  local arr_name="$1"
  local -n arr_ref="$arr_name"
  local idx
  idx="$(rand_range 0 $(( ${#arr_ref[@]} - 1 )) )"
  echo "${arr_ref[$idx]}"
}

rand_prob() {
  local p="$1"
  local x
  x="$(rand_range 1 100)"
  [[ "$x" -le "$p" ]]
}

# -------------------------
# 3) Helpers
# -------------------------
slugify() {
  local s="$1"
  s="${s,,}"
  s="$(echo "$s" | sed -E 's/[^a-z0-9]+/./g; s/\.+/./g; s/^\.//; s/\.$//')"
  echo "$s"
}

split_two_words() {
  local full="$1"
  local first rest
  first="${full%% *}"
  rest="${full#* }"
  if [[ "$first" == "$rest" ]]; then
    rest="$first"
  fi
  echo "${first}|${rest}"
}

b64() {
  printf '%s' "$1" | openssl base64 -A
}

ssha_hash() {
  local password="$1"
  local salt_hex sha1_hex digest_hex out_b64
  salt_hex="$(openssl rand -hex 4)"
  sha1_hex="$(
    { printf '%s' "$password"; printf '%s' "$salt_hex" | xxd -r -p; } \
      | openssl dgst -sha1 -binary | xxd -p -c 256
  )"
  digest_hex="${sha1_hex}${salt_hex}"
  out_b64="$(printf '%s' "$digest_hex" | xxd -r -p | openssl base64 -A)"
  printf '{SSHA}%s' "$out_b64"
}

generate_uid() {
  local index="$1"
  printf 'ani%04d' "$index"
}

build_mail() {
  local local_part="$1"
  local sub
  sub="$(rand_choice MAIL_SUBDOMAINS)"
  echo "${local_part}@${sub}.petra.ac.id"
}

build_mail_alternates() {
  local handle="$1"
  local alt_sub
  alt_sub="$(rand_choice MAIL_SUBDOMAINS)"
  echo "${handle}@alumni.petra.ac.id|${handle}@google.com|${handle}@yahoo.com|${handle}@${alt_sub}.petra.ac.id"
}

generate_nik() {
  local gender="$1"
  local region year month day dob seq
  region="$(rand_choice NIK_REGION_CODES)"
  year="$(rand_range 1970 2005)"
  month="$(rand_range 1 12)"
  day="$(rand_range 1 28)"

  if [[ "${gender,,}" == "f" ]]; then
    day=$(( day + 40 ))
  fi

  dob="$(printf '%02d%02d%02d' "$day" "$month" "$(( year % 100 ))")"
  seq="$(printf '%04d' "$(rand_range 1 9999)")"
  echo "${region}${dob}${seq}"
}

pick_status() {
  echo "$(rand_choice STATUSES)"
}

pick_role_cn() {
  echo "$(rand_choice ROLE_CNS)"
}

role_dn_from_cn() {
  local role_cn="$1"
  echo "cn=${role_cn},${ROLES_DN}"
}

append_user_entry() {
  local dn="$1" uid="$2" cn="$3" sn="$4" given="$5" display="$6" mail="$7"
  local alt1="$8" alt2="$9" alt3="${10}" alt4="${11}"
  local userNIK="${12}"
  local affiliation="${13}"
  local status="${14}"

  local pw_hash pw_b64
  pw_hash="$(ssha_hash "$PASSWORD")"
  pw_b64="$(b64 "$pw_hash")"

  {
    echo "dn: ${dn}"
    echo "objectClass: inetOrgPerson"
    echo "objectClass: petraPerson"
    echo "uid: ${uid}"
    echo "cn: ${cn}"
    echo "sn: ${sn}"
    echo "givenName: ${given}"
    echo "displayName: ${display}"
    echo "mail: ${mail}"
    echo "mailAlternateAddress: ${alt1}"
    echo "mailAlternateAddress: ${alt2}"
    echo "mailAlternateAddress: ${alt3}"
    echo "mailAlternateAddress: ${alt4}"
    echo "userNIK: ${userNIK}"
    echo "petraAffiliation: ${affiliation}"
    echo "petraAccountStatus: ${status}"
    echo "userPassword:: ${pw_b64}"
    echo ""
  } >> "$OUT_USERS"
}

append_group_add_member() {
  local role_dn="$1"
  local user_dn="$2"

  {
    echo "dn: ${role_dn}"
    echo "changetype: modify"
    echo "add: member"
    echo "member: ${user_dn}"
    echo "-"
    echo ""
  } >> "$OUT_GROUPS"
}

append_revert_remove_member() {
  local role_dn="$1"
  local user_dn="$2"

  {
    echo "dn: ${role_dn}"
    echo "changetype: modify"
    echo "delete: member"
    echo "member: ${user_dn}"
    echo "-"
    echo ""
  } >> "$REVERT_OUT"
}

append_revert_delete_user() {
  local user_dn="$1"

  {
    echo "dn: ${user_dn}"
    echo "changetype: delete"
    echo ""
  } >> "$REVERT_OUT"
}

# -------------------------
# 4) Prepare outputs
# -------------------------
mkdir -p "$(dirname "$OUT_USERS")" "$(dirname "$OUT_GROUPS")" "$(dirname "$REVERT_OUT")"

TS="$(date -Iseconds)"

{
  echo "# 03-users-animals-20.generated.ldif"
  echo "# Generated: ${TS}"
  echo "# Base DN: ${BASE_DN}"
  echo "# Target DN: ${PEOPLE_DN}"
  echo "# Total entities: 20"
  echo "# uid format: ani0001..ani0020"
  echo "# petraAffiliation = exact role cn"
  echo "#"
} > "$OUT_USERS"

{
  echo "# 04-role-memberships-animals-20.generated.ldif"
  echo "# Generated: ${TS}"
  echo "# Adds each generated user into exactly one role group"
  echo "#"
} > "$OUT_GROUPS"

{
  echo "# 05-revert-animals-20.generated.ldif"
  echo "# Generated: ${TS}"
  echo "# First remove role memberships, then delete users"
  echo "#"
} > "$REVERT_OUT"

# -------------------------
# 5) Generate 20 users
# -------------------------
for i in $(seq 1 20); do
  full="${ANIMAL_NAMES[$((i-1))]}"

  IFS='|' read -r given sn <<< "$(split_two_words "$full")"
  cn="${given} ${sn}"

  uid="$(generate_uid "$i")"
  user_dn="uid=${uid},${PEOPLE_DN}"

  mail_local="$(slugify "${given}.${sn}.${uid}")"
  mail="$(build_mail "$mail_local")"

  handle="$(slugify "${given}.${sn}")"
  IFS='|' read -r alt1 alt2 alt3 alt4 <<< "$(build_mail_alternates "$handle")"

  gender="m"
  if rand_prob 45; then
    gender="f"
  fi

  nik="$(generate_nik "$gender")"
  role_cn="$(pick_role_cn)"
  role_dn="$(role_dn_from_cn "$role_cn")"
  status="$(pick_status)"

  append_user_entry \
    "$user_dn" "$uid" "$cn" "$sn" "$given" "$cn" "$mail" \
    "$alt1" "$alt2" "$alt3" "$alt4" \
    "$nik" "$role_cn" "$status"

  append_group_add_member "$role_dn" "$user_dn"
  append_revert_remove_member "$role_dn" "$user_dn"
  append_revert_delete_user "$user_dn"
done

echo "OK: wrote:"
echo "  - ${OUT_USERS}"
echo "  - ${OUT_GROUPS}"
echo "  - ${REVERT_OUT}"
echo "All users inserted directly under: ${PEOPLE_DN}"
echo "petraAffiliation = exact role cn"
#!/usr/bin/env bash
# Petra IAM - Generate 100 LDAP entities + rollback (revert) LDIFs (Bash only)
# Output:
#  - ldif/03-users.generated.ldif
#  - ldif/05-revert-100.generated.ldif
#
# Run:
#   bash scripts/gen_ldap_entities_100_v2.sh \
#     --out ldif/03-users.generated.ldif \
#     --revert-out ldif/05-revert-100.generated.ldif \
#     --password 'SeongJinWoo999!' \
#     --seed 20260216
#
# Populate:
#   ldapadd -x -H ldap://127.0.0.1:389 \
#     -D "cn=admin,dc=petra,dc=ac,dc=id" -w SeongJinWoo999! \
#     -f ldif/03-users.generated.ldif
#
# Revert:
#   ldapmodify -x -H ldap://127.0.0.1:389 \
#     -D "cn=admin,dc=petra,dc=ac,dc=id" -w SeongJinWoo999! \
#     -f ldif/05-revert-100.generated.ldif

set -euo pipefail

# -------------------------
# 1) Defaults & args
# -------------------------
SEED="20260216"
PASSWORD="SeongJinWoo999!"
OUT="ldif/03-users.generated.ldif"
REVERT_OUT="ldif/05-revert-100.generated.ldif"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed) SEED="${2:-}"; shift 2;;
    --password) PASSWORD="${2:-}"; shift 2;;
    --out) OUT="${2:-}"; shift 2;;
    --revert-out) REVERT_OUT="${2:-}"; shift 2;;
    -h|--help)
      sed -n '1,60p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl not found. Install openssl for SSHA hashing." >&2
  exit 1
fi

BASE_DN="dc=petra,dc=ac,dc=id"
PEOPLE_DN="ou=people,${BASE_DN}"

OU_STUDENTS="ou=students,${PEOPLE_DN}"
OU_STAFF="ou=staff,${PEOPLE_DN}"
OU_ALUMNI="ou=alumni,${PEOPLE_DN}"
OU_EXTERNAL="ou=external,${PEOPLE_DN}"

MAIL_SUBDOMAINS=( "john" "peter" "petra" )

NIK_REGION_CODES=(
  "357801" "351501" "351401" "327301" "317401"
  "317301" "337401" "347101" "517101" "127101"
)

# -------------------------
# 2) Deterministic RNG (seeded)
# -------------------------
# LCG 31-bit
RSTATE=$(( (SEED + 0) & 0x7fffffff ))
rand_u31() {
  # glibc-like LCG
  RSTATE=$(( (1103515245 * RSTATE + 12345) & 0x7fffffff ))
  echo "$RSTATE"
}
rand_range() { # [min,max]
  local min="$1" max="$2"
  local r
  r="$(rand_u31)"
  echo $(( min + (r % (max - min + 1)) ))
}
rand_choice() { # array name
  local arr_name="$1"
  local -n arr_ref="$arr_name"
  local idx
  idx="$(rand_range 0 $(( ${#arr_ref[@]} - 1 )) )"
  echo "${arr_ref[$idx]}"
}
rand_prob() { # prob_0_100
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
  # replace non-alnum with dot
  s="$(echo "$s" | sed -E 's/[^a-z0-9]+/./g; s/\.+/./g; s/^\.//; s/\.$//')"
  echo "$s"
}

split_two_words() {
  # output: "given|sn"
  local full="$1"
  # shellsplit by spaces
  local first rest
  first="${full%% *}"
  rest="${full#* }"
  if [[ "$first" == "$rest" ]]; then
    rest="$first"
  fi
  echo "${first}|${rest}"
}

b64() {
  # base64 without newline
  printf '%s' "$1" | openssl base64 -A
}

ssha_hash() {
  # {SSHA} base64( SHA1(password+salt) + salt ), salt 4 bytes
  local password="$1"
  local salt_hex sha1_hex digest_hex out_b64
  salt_hex="$(openssl rand -hex 4)"
  # sha1 of (password bytes + salt bytes)
  sha1_hex="$(
    { printf '%s' "$password"; printf '%s' "$salt_hex" | xxd -r -p; } \
      | openssl dgst -sha1 -binary | xxd -p -c 256
  )"
  digest_hex="${sha1_hex}${salt_hex}"
  out_b64="$(printf '%s' "$digest_hex" | xxd -r -p | openssl base64 -A)"
  printf '{SSHA}%s' "$out_b64"
}

build_mail() {
  local local_part="$1"
  local sub
  sub="$(rand_choice MAIL_SUBDOMAINS)"
  echo "${local_part}@${sub}.petra.ac.id"
}

build_mail_alternates() {
  # MUST ALWAYS exactly 4 values (order fixed)
  local handle="$1"
  local alt_sub
  alt_sub="$(rand_choice MAIL_SUBDOMAINS)"
  echo "${handle}@alumni.petra.ac.id|${handle}@google.com|${handle}@yahoo.com|${handle}@${alt_sub}.petra.ac.id"
}

# UUIDv7-like generator in shell:
# time_ms (48 bits) + version 7 + rand
uuid7_str() {
  # We build 16 bytes:
  # bytes0-5: timestamp ms big-endian (48-bit)
  # bytes6: high nibble version=7, low nibble random
  # bytes7: random
  # byte8: variant 10xx + 6 random bits
  # bytes9-15: random
  local ts_ms ts_hex b0 b1 b2 b3 b4 b5
  ts_ms="$(date -u +%s%3N)"
  # keep 48 bits
  ts_ms=$(( ts_ms & 0xFFFFFFFFFFFF ))
  ts_hex="$(printf '%012x' "$ts_ms")"
  b0="${ts_hex:0:2}"
  b1="${ts_hex:2:2}"
  b2="${ts_hex:4:2}"
  b3="${ts_hex:6:2}"
  b4="${ts_hex:8:2}"
  b5="${ts_hex:10:2}"

  local r6 r7 r8 rrest hex32
  r6="$(printf '%02x' "$(rand_range 0 255)")"
  r7="$(printf '%02x' "$(rand_range 0 255)")"
  r8="$(printf '%02x' "$(rand_range 0 255)")"

  # set version=7 on byte6 high nibble
  r6="$(printf '%02x' "$(( (0x$r6 & 0x0F) | 0x70 ))")"
  # set variant 10xx on byte8
  r8="$(printf '%02x' "$(( (0x$r8 & 0x3F) | 0x80 ))")"

  # remaining 7 bytes random (bytes9-15)
  rrest=""
  for _ in {1..7}; do
    rrest+=$(printf '%02x' "$(rand_range 0 255)")
  done

  hex32="${b0}${b1}${b2}${b3}${b4}${b5}${r6}${r7}${r8}${rrest}"
  echo "${hex32:0:8}-${hex32:8:4}-${hex32:12:4}-${hex32:16:4}-${hex32:20:12}"
}

generate_nik() {
  # NIK: region6 + ddmmyy(with female day+40) + seq4
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

generate_student_number() {
  # <Letter><2digits angkatan><2digits prodi><4digits urut>
  local level="$1"
  local letter_idx letter angkatan prodi urut

  letter_idx="$(rand_range 0 25)"
  letter="$(printf "\\$(printf '%03o' $((65 + letter_idx)) )")"

  case "$level" in
    S1) angkatan="$(rand_range 14 23)";;
    S2) angkatan="$(rand_range 15 25)";;
    S3) angkatan="$(rand_range 16 26)";;
    *) angkatan="$(rand_range 14 26)";;
  esac

  prodi="$(rand_range 10 99)"
  urut="$(rand_range 1 9999)"
  printf '%s%02d%02d%04d' "$letter" "$angkatan" "$prodi" "$urut"
}

generate_employee_number() {
  # 6-10 digits
  local length first rest i
  length="$(rand_choice EMP_LEN)"
}
# define EMP_LEN after function reference is okay in bash? safer define now:
EMP_LEN=(6 7 8 9 10)

generate_employee_number() {
  local length first rest i
  length="$(rand_choice EMP_LEN)"
  first="$(rand_range 1 9)"
  rest=""
  for ((i=1; i<length; i++)); do
    rest+=$(rand_range 0 9)
  done
  echo "${first}${rest}"
}

scenario_for_human() {
  # output: "student_active|student_hist_csv|employeeNumber"
  local ou_key="$1"

  if [[ "$ou_key" == "students" ]]; then
    # pick with weights: 40,20,10,15,15
    local pick_r
    pick_r="$(rand_range 1 100)"
    local pick
    if   [[ "$pick_r" -le 40 ]]; then pick="S1_only"
    elif [[ "$pick_r" -le 60 ]]; then pick="S2_only"
    elif [[ "$pick_r" -le 70 ]]; then pick="S3_only"
    elif [[ "$pick_r" -le 85 ]]; then pick="S2_working"
    else pick="S1_working"
    fi

    if [[ "$pick" == "S1_only" ]]; then
      echo "$(generate_student_number S1)||"
      return
    fi

    if [[ "$pick" == "S2_only" ]]; then
      local active hist=""
      active="$(generate_student_number S2)"
      if rand_prob 70; then hist="$(generate_student_number S1)"; fi
      echo "${active}|${hist}|"
      return
    fi

    if [[ "$pick" == "S3_only" ]]; then
      local active h1 h2 hist
      active="$(generate_student_number S3)"
      h1="$(generate_student_number S2)"
      hist="$h1"
      if rand_prob 60; then
        h2="$(generate_student_number S1)"
        hist="${hist},${h2}"
      fi
      echo "${active}|${hist}|"
      return
    fi

    if [[ "$pick" == "S2_working" ]]; then
      local active hist emp
      active="$(generate_student_number S2)"
      hist="$(generate_student_number S1)"
      emp="$(generate_employee_number)"
      echo "${active}|${hist}|${emp}"
      return
    fi

    if [[ "$pick" == "S1_working" ]]; then
      local active emp
      active="$(generate_student_number S1)"
      emp="$(generate_employee_number)"
      echo "${active}||${emp}"
      return
    fi
  fi

  if [[ "$ou_key" == "staff" ]]; then
    # weights 60/40
    if rand_prob 60; then
      echo "||$(generate_employee_number)"
    else
      local hist emp lvl
      lvl="$(rand_choice LVL)"
      hist="$(generate_student_number "$lvl")"
      emp="$(generate_employee_number)"
      echo "|${hist}|${emp}"
    fi
    return
  fi

  if [[ "$ou_key" == "alumni" ]]; then
    local lvl hist
    lvl="$(rand_choice LVL)"
    hist="$(generate_student_number "$lvl")"
    echo "|${hist}|"
    return
  fi

  # external
  echo "||"
}

LVL=(S1 S2 S3)

status_for_index() {
  # 80 active, 10 disabled, 10 suspended (shuffled)
  # We'll prebuild statuses array.
  local idx="$1"
  echo "${STATUSES[$idx]}"
}

# -------------------------
# 4) Data lists (must 50 each)
# -------------------------
HUMAN_FULLNAMES=(
  "Aditya Pratama" "Bima Saputra" "Cahya Wibowo" "Dimas Setiawan" "Eka Santoso"
  "Farhan Hidayat" "Gilang Nugroho" "Hana Putri" "Iqbal Ramadhan" "Jihan Permata"
  "Kurniawan Siregar" "Laila Anggraini" "Made Wirawan" "Nabila Maharani" "Oka Prasetyo"
  "Putri Lestari" "Raisa Octaviani" "Satria Gunawan" "Tania Kartika" "Utami Sari"
  "Vito Mahendra" "Wulan Purnama" "Yusuf Kurnia" "Zahra Aulia" "Bagas Wijaya"
  "Chandra Surya" "Dara Amelia" "Elang Prakoso" "Fadli Saputro" "Gita Puspita"
  "Hendra Firmansyah" "Indra Kusuma" "Jelita Damayanti" "Kevin Hartono" "Luthfi Prabowo"
  "Mita Anindya" "Nanda Pramana" "Olin Nirmala" "Prita Wulandari" "Rangga Pamungkas"
  "Sinta Marcellina" "Taufik Akbar" "Umar Fadillah" "Vania Safitri" "Wahyu Hapsari"
  "Yohana Kristina" "Zaki Firmanto" "Arga Prameswara" "Bella Candrawati" "Citra Permadi"
)

NONHUMAN_NAMES=(
  "Nova Dynamics" "Atlas Forge" "Quantum Harbor" "Pixel Foundry" "Garuda Systems"
  "Ember Studio" "Aurora Ventures" "Nimbus Works" "Prism Logistics" "Kencana Mart"
  "Sagara Foods" "Merapi Digital" "Bintang Fabric" "Cakra Motors" "Lentera Labs"
  "Nusantara Cloud" "Arunika Media" "Tirta Supply" "Rajawali Cargo" "Samudra Tech"
  "Pertiwi Energy" "Seruni Pharma" "Pelangi Retail" "Borneo Trading" "Bali Botanics"
  "Sulawesi Mining" "Sumatra Agro" "Jawa Textiles" "Kalimantan Timber" "Komodo Travel"
  "Mentari Finance" "Langit Telecom" "Rimba Outfitters" "Batu Brew" "Kopi Corner"
  "Sate Station" "Roti Republic" "Ayam Avenue" "Teh Terrace" "Nasi Network"
  "Hydro Pulse" "Solar Crescent" "Titan Fabrication" "Orbit Appliance" "Zenith Analytics"
  "Vertex Security" "Cedar Capital" "Marble Atelier" "Oceanic Portfolio" "Crystal District"
)

if [[ "${#HUMAN_FULLNAMES[@]}" -ne 50 || "${#NONHUMAN_NAMES[@]}" -ne 50 ]]; then
  echo "ERROR: Name lists must be exactly 50 each." >&2
  exit 1
fi

# -------------------------
# 5) Status array (shuffled)
# -------------------------
STATUSES=()
for _ in {1..80}; do STATUSES+=( "active" ); done
for _ in {1..10}; do STATUSES+=( "disabled" ); done
for _ in {1..10}; do STATUSES+=( "suspended" ); done

# Fisher-Yates shuffle using seeded RNG
for ((i=${#STATUSES[@]}-1; i>0; i--)); do
  j="$(rand_range 0 "$i")"
  tmp="${STATUSES[$i]}"
  STATUSES[$i]="${STATUSES[$j]}"
  STATUSES[$j]="$tmp"
done

# -------------------------
# 6) Plans (100)
# -------------------------
# humans: students=30, staff=12, alumni=6, external=2
HUMAN_PLAN=()
for _ in {1..30}; do HUMAN_PLAN+=( "students" ); done
for _ in {1..12}; do HUMAN_PLAN+=( "staff" ); done
for _ in {1..6};  do HUMAN_PLAN+=( "alumni" ); done
for _ in {1..2};  do HUMAN_PLAN+=( "external" ); done

# nonhuman: external=50
NONHUMAN_PLAN=()
for _ in {1..50}; do NONHUMAN_PLAN+=( "external" ); done

# -------------------------
# 7) LDIF writers
# -------------------------
mkdir -p "$(dirname "$OUT")" "$(dirname "$REVERT_OUT")"

TS="$(date -Iseconds)"
{
  echo "# 03-users.generated.ldif"
  echo "# Generated: ${TS}"
  echo "# Base DN: ${BASE_DN}"
  echo "# Entities: 100 (50 human, 50 non-human)"
  echo "# uid: UUIDv7-like"
  echo "# userNIK: Indonesian NIK (16 digits, realistic format) for human entries"
  echo "# studentNumber: active NRP/NIM (optional)"
  echo "# studentNumberHistory: multi-value history (optional)"
  echo "# employeeNumber: optional (staff / working students scenarios)"
  echo "# mail domains: john.petra.ac.id / peter.petra.ac.id / petra.petra.ac.id (random)"
  echo "# mailAlternateAddress ALWAYS includes: alumni.petra.ac.id + google.com + yahoo.com + one-of john/peter/petra.petra.ac.id"
  echo "#"
} > "$OUT"

: > "$REVERT_OUT"
{
  echo "# 05-revert-100.generated.ldif (DELETE the 100 generated entities)"
  echo "# Generated: ${TS}"
  echo "#"
} >> "$REVERT_OUT"

append_entry() {
  local dn="$1" uid="$2" cn="$3" sn="$4" given="$5" display="$6" mail="$7"
  local alt1="$8" alt2="$9" alt3="${10}" alt4="${11}"
  local userNIK="${12:-}"
  local affiliation="${13}" status="${14}"
  local studentNumber="${15:-}"
  local studentHistoryCSV="${16:-}"
  local employeeNumber="${17:-}"

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
    if [[ -n "${userNIK}" ]]; then
      echo "userNIK: ${userNIK}"
    fi
    echo "petraAffiliation: ${affiliation}"
    echo "petraAccountStatus: ${status}"

    if [[ -n "${studentNumber}" ]]; then
      echo "studentNumber: ${studentNumber}"
    fi

    if [[ -n "${studentHistoryCSV}" ]]; then
      IFS=',' read -r -a hist_arr <<< "$studentHistoryCSV"
      for h in "${hist_arr[@]}"; do
        [[ -n "$h" ]] && echo "studentNumberHistory: ${h}"
      done
    fi

    if [[ -n "${employeeNumber}" ]]; then
      echo "employeeNumber: ${employeeNumber}"
    fi

    echo "userPassword:: ${pw_b64}"
    echo ""
  } >> "$OUT"

  {
    echo "dn: ${dn}"
    echo "changetype: delete"
    echo ""
  } >> "$REVERT_OUT"
}

ou_dn_for_key() {
  local k="$1"
  case "$k" in
    students) echo "$OU_STUDENTS";;
    staff) echo "$OU_STAFF";;
    alumni) echo "$OU_ALUMNI";;
    external) echo "$OU_EXTERNAL";;
    *) echo "$OU_EXTERNAL";;
  esac
}

# -------------------------
# 8) Generate 50 humans
# -------------------------
sidx=0

for i in "${!HUMAN_FULLNAMES[@]}"; do
  full="${HUMAN_FULLNAMES[$i]}"
  ou_key="${HUMAN_PLAN[$i]}"

  IFS='|' read -r given sn <<< "$(split_two_words "$full")"
  cn="${given} ${sn}"

  uid="$(uuid7_str)"
  dn="uid=${uid},$(ou_dn_for_key "$ou_key")"

  mail_local="$(slugify "${given}.${uid:0:8}")"
  mail="$(build_mail "$mail_local")"

  handle="$(slugify "${given}.${sn}")"
  IFS='|' read -r alt1 alt2 alt3 alt4 <<< "$(build_mail_alternates "$handle")"

  # gender 45% female
  gender="m"
  if rand_prob 45; then gender="f"; fi
  nik="$(generate_nik "$gender")"

  case "$ou_key" in
    students) affiliation="student";;
    staff) affiliation="staff";;
    alumni) affiliation="alumni";;
    external) affiliation="external";;
    *) affiliation="external";;
  esac

  IFS='|' read -r student_active student_hist emp_no <<< "$(scenario_for_human "$ou_key")"
  status="${STATUSES[$sidx]}"
  sidx=$((sidx+1))

  append_entry \
    "$dn" "$uid" "$cn" "$sn" "$given" "$cn" "$mail" \
    "$alt1" "$alt2" "$alt3" "$alt4" \
    "$nik" "$affiliation" "$status" \
    "${student_active:-}" "${student_hist:-}" "${emp_no:-}"
done

# -------------------------
# 9) Generate 50 non-humans (external)
# -------------------------
for i in "${!NONHUMAN_NAMES[@]}"; do
  name="${NONHUMAN_NAMES[$i]}"
  ou_key="${NONHUMAN_PLAN[$i]}"

  IFS='|' read -r given sn <<< "$(split_two_words "$name")"
  cn="${given} ${sn}"

  uid="$(uuid7_str)"
  dn="uid=${uid},$(ou_dn_for_key "$ou_key")"

  mail_local="$(slugify "$given")"
  mail="$(build_mail "$mail_local")"

  handle="$(slugify "${given}.${sn}")"
  IFS='|' read -r alt1 alt2 alt3 alt4 <<< "$(build_mail_alternates "$handle")"

  status="${STATUSES[$sidx]}"
  sidx=$((sidx+1))

  append_entry \
    "$dn" "$uid" "$cn" "$sn" "$given" "$cn" "$mail" \
    "$alt1" "$alt2" "$alt3" "$alt4" \
    "" "external" "$status" \
    "" "" ""
done

echo "OK: wrote ${OUT} and ${REVERT_OUT}"
echo "UID: UUIDv7-like for all entries"
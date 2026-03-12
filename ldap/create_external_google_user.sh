#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config LDAP kamu
# =========================
LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:389}"
BIND_DN="${BIND_DN:-cn=admin,dc=petra,dc=ac,dc=id}"
BIND_PW="${BIND_PW:-SeongJinWoo999!}"

BASE_DN="dc=petra,dc=ac,dc=id"
PEOPLE_DN="ou=people,${BASE_DN}"
EXTERNAL_OU_DN="ou=external,${PEOPLE_DN}"

# =========================
# Data user yang kamu minta
# =========================
GIVEN_NAME="Abiel"
SN="Nathanael"
CN="Abiel Nathanael"
DISPLAY_NAME="Abiel Nathanael"
MAIL="abielpasaribu@gmail.com"
PASSWORD_PLAIN="Bernadethe20"
AFFILIATION="external"
STATUS="active"

# =========================
# Helper: UUIDv7 generator (pure python, no library)
# =========================
UUIDV7="$(python3 - <<'PY'
import os, time, secrets
# UUIDv7 draft-ish: 48-bit unix ms timestamp + 74 bits random (with version/variant bits)
ts_ms = int(time.time() * 1000) & ((1<<48)-1)
rand = secrets.randbits(74)

# Build 128-bit int:
# time_high(48) | version(4=0b0111) | rand_a(12) | variant(2=0b10) | rand_b(62)
rand_a = (rand >> 62) & ((1<<12)-1)
rand_b = rand & ((1<<62)-1)

uuid_int = (ts_ms << 80)  # shift into top 48 bits position
uuid_int |= (0x7 << 76)   # version 7 in next 4 bits
uuid_int |= (rand_a << 64)
uuid_int |= (0x2 << 62)   # RFC 4122 variant '10'
uuid_int |= rand_b

hexs = f"{uuid_int:032x}"
u = f"{hexs[0:8]}-{hexs[8:12]}-{hexs[12:16]}-{hexs[16:20]}-{hexs[20:32]}"
print(u)
PY
)"

USER_DN="uid=${UUIDV7},${EXTERNAL_OU_DN}"

echo "[+] LDAP_URI   : ${LDAP_URI}"
echo "[+] USER_DN    : ${USER_DN}"
echo "[+] MAIL       : ${MAIL}"
echo

# =========================
# Pastikan OU external ada
# =========================
echo "[+] Checking OU external exists..."
if ! ldapsearch -x -H "${LDAP_URI}" -D "${BIND_DN}" -w "${BIND_PW}" -b "${EXTERNAL_OU_DN}" "(objectClass=organizationalUnit)" dn >/dev/null 2>&1; then
  echo "[!] OU external not found. Creating it..."
  cat > /tmp/ou_external.ldif <<EOF
dn: ${EXTERNAL_OU_DN}
objectClass: top
objectClass: organizationalUnit
ou: external
description: External users (Google / partners / guests)
EOF

  ldapadd -x -H "${LDAP_URI}" -D "${BIND_DN}" -w "${BIND_PW}" -f /tmp/ou_external.ldif
  echo "[+] OU external created."
else
  echo "[+] OU external already exists."
fi
echo

# =========================
# Generate SSHA password hash
# =========================
echo "[+] Generating SSHA hash..."
if ! command -v slappasswd >/dev/null 2>&1; then
  echo "[ERROR] slappasswd not found. Install it:"
  echo "        apt-get update && apt-get install -y slapd ldap-utils"
  exit 1
fi

SSHA_HASH="$(slappasswd -h '{SSHA}' -s "${PASSWORD_PLAIN}")"
echo "[+] SSHA_HASH  : ${SSHA_HASH}"
echo

# =========================
# Buat LDIF user
# =========================
LDIF="/tmp/user_external_google_abiel.ldif"
cat > "${LDIF}" <<EOF
dn: ${USER_DN}
objectClass: inetOrgPerson
objectClass: petraPerson
uid: ${UUIDV7}
cn: ${CN}
sn: ${SN}
givenName: ${GIVEN_NAME}
displayName: ${DISPLAY_NAME}
mail: ${MAIL}
mailAlternateAddress: abiel.nathanael@alumni.petra.ac.id
mailAlternateAddress: abiel.nathanael@yahoo.com
mailAlternateAddress: abiel.nathanael@google.com
petraAffiliation: ${AFFILIATION}
petraAccountStatus: ${STATUS}
userPassword: ${SSHA_HASH}
EOF

echo "[+] LDIF created at ${LDIF}"
echo

# =========================
# Add user to LDAP
# =========================
echo "[+] Adding user..."
ldapadd -x -H "${LDAP_URI}" -D "${BIND_DN}" -w "${BIND_PW}" -f "${LDIF}"

echo
echo "[✅ DONE] User created!"
echo "UID (uuidv7): ${UUIDV7}"
echo "DN          : ${USER_DN}"
echo "mail        : ${MAIL}"

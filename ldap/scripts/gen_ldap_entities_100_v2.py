#!/usr/bin/env python3
"""
Petra IAM - Generate 100 LDAP entities + rollback (revert) LDIFs

✅ New Model (per keputusan kita):
- uid = UUIDv7 (dipakai di DN + attribute uid)
- userNIK = NIK Indonesia (16 digit, realistis) -> pengganti petraUUID
- studentNumber = NRP aktif (opsional, boleh kosong)
- studentNumberHistory = riwayat NRP (MULTI-VALUE)
- employeeNumber = NIP (opsional, kalau staff / kerja sambil kuliah)
- mailAlternateAddress: MUST ALWAYS exactly 4 values

✅ Output:
- ldif/03-users.generated.ldif      (ldapadd)
- ldif/05-revert-100.generated.ldif (ldapmodify delete)

Run:
  python3 scripts/gen_ldap_entities_100_v2.py \
    --out ldif/03-users.generated.ldif \
    --revert-out ldif/05-revert-100.generated.ldif \
    --password 'SeongJinWoo999!'

Populate:
  ldapadd -x -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=petra,dc=ac,dc=id" -w SeongJinWoo999! \
    -f ldif/03-users.generated.ldif

Revert:
  ldapmodify -x -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=petra,dc=ac,dc=id" -w SeongJinWoo999! \
    -f ldif/05-revert-100.generated.ldif
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import random
import re
from datetime import datetime
from typing import Iterable, Optional


BASE_DN = "dc=petra,dc=ac,dc=id"
PEOPLE_DN = f"ou=people,{BASE_DN}"

OU_DNS = {
    "students": f"ou=students,{PEOPLE_DN}",
    "staff": f"ou=staff,{PEOPLE_DN}",
    "alumni": f"ou=alumni,{PEOPLE_DN}",
    "external": f"ou=external,{PEOPLE_DN}",
}

MAIL_SUBDOMAINS = ["john", "peter", "petra"]  # -> <sub>.petra.ac.id

# 50 Indonesian human names (2 words)
HUMAN_FULLNAMES: list[str] = [
    "Aditya Pratama","Bima Saputra","Cahya Wibowo","Dimas Setiawan","Eka Santoso",
    "Farhan Hidayat","Gilang Nugroho","Hana Putri","Iqbal Ramadhan","Jihan Permata",
    "Kurniawan Siregar","Laila Anggraini","Made Wirawan","Nabila Maharani","Oka Prasetyo",
    "Putri Lestari","Raisa Octaviani","Satria Gunawan","Tania Kartika","Utami Sari",
    "Vito Mahendra","Wulan Purnama","Yusuf Kurnia","Zahra Aulia","Bagas Wijaya",
    "Chandra Surya","Dara Amelia","Elang Prakoso","Fadli Saputro","Gita Puspita",
    "Hendra Firmansyah","Indra Kusuma","Jelita Damayanti","Kevin Hartono","Luthfi Prabowo",
    "Mita Anindya","Nanda Pramana","Olin Nirmala","Prita Wulandari","Rangga Pamungkas",
    "Sinta Marcellina","Taufik Akbar","Umar Fadillah","Vania Safitri","Wahyu Hapsari",
    "Yohana Kristina","Zaki Firmanto","Arga Prameswara","Bella Candrawati","Citra Permadi",
]

# 50 non-human 2-word names (company/division/product-style)
NONHUMAN_NAMES: list[str] = [
    "Nova Dynamics","Atlas Forge","Quantum Harbor","Pixel Foundry","Garuda Systems",
    "Ember Studio","Aurora Ventures","Nimbus Works","Prism Logistics","Kencana Mart",
    "Sagara Foods","Merapi Digital","Bintang Fabric","Cakra Motors","Lentera Labs",
    "Nusantara Cloud","Arunika Media","Tirta Supply","Rajawali Cargo","Samudra Tech",
    "Pertiwi Energy","Seruni Pharma","Pelangi Retail","Borneo Trading","Bali Botanics",
    "Sulawesi Mining","Sumatra Agro","Jawa Textiles","Kalimantan Timber","Komodo Travel",
    "Mentari Finance","Langit Telecom","Rimba Outfitters","Batu Brew","Kopi Corner",
    "Sate Station","Roti Republic","Ayam Avenue","Teh Terrace","Nasi Network",
    "Hydro Pulse","Solar Crescent","Titan Fabrication","Orbit Appliance","Zenith Analytics",
    "Vertex Security","Cedar Capital","Marble Atelier","Oceanic Portfolio","Crystal District",
]

# Beberapa contoh kode wilayah 6 digit (prov-kab-kec) untuk bikin NIK realistis
# (Ini bukan validasi resmi Dukcapil, tapi formatnya benar & realistis)
NIK_REGION_CODES = [
    "357801",  # Surabaya
    "351501",  # Sidoarjo
    "351401",  # Gresik
    "327301",  # Bandung
    "317401",  # Jakarta Selatan
    "317301",  # Jakarta Barat
    "337401",  # Semarang
    "347101",  # Yogyakarta
    "517101",  # Denpasar
    "127101",  # Medan
]


def split_two_words(full: str) -> tuple[str, str]:
    parts = full.strip().split()
    if len(parts) < 2:
        return (parts[0], parts[0])
    return (parts[0], " ".join(parts[1:]))


def slugify(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9]+", ".", s)
    s = re.sub(r"\.+", ".", s).strip(".")
    return s


def ssha_hash(password: str) -> str:
    """Generate OpenLDAP-compatible {SSHA} (SHA1 + salt)."""
    salt = os.urandom(4)
    sha1 = hashlib.sha1(password.encode("utf-8") + salt).digest()
    return "{SSHA}" + base64.b64encode(sha1 + salt).decode("ascii")


def b64_ldif_value(value: str) -> str:
    """Return base64-encoded value for LDIF double-colon style."""
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def build_mail(local_part: str) -> str:
    sub = random.choice(MAIL_SUBDOMAINS)
    return f"{local_part}@{sub}.petra.ac.id"


def build_mail_alternates(handle: str) -> list[str]:
    # MUST ALWAYS contain these 4 values (order fixed for predictability)
    alt_sub = random.choice(MAIL_SUBDOMAINS)
    return [
        f"{handle}@alumni.petra.ac.id",
        f"{handle}@google.com",
        f"{handle}@yahoo.com",
        f"{handle}@{alt_sub}.petra.ac.id",
    ]


# ---------------------------
# UUIDv7 generator (no deps)
# ---------------------------
def uuid7_str() -> str:
    """
    Generate a UUIDv7-like string (time-ordered).
    Spec-accurate UUIDv7 needs RFC implementation, but for IAM demo this is enough:
    - first 48 bits = unix epoch ms
    - set version=7
    - set variant=10xx
    - remaining random
    """
    ts_ms = int(datetime.utcnow().timestamp() * 1000) & ((1 << 48) - 1)
    rand_a = random.getrandbits(12)
    rand_b = random.getrandbits(62)

    # Build 128-bit:
    # time(48) | ver(4=0111) | rand_a(12) | variant(2=10) | rand_b(62)
    uuid_int = (ts_ms << (128 - 48))
    uuid_int |= (0x7 << (128 - 48 - 4))
    uuid_int |= (rand_a << (128 - 48 - 4 - 12))
    uuid_int |= (0x2 << (128 - 48 - 4 - 12 - 2))  # variant '10'
    uuid_int |= rand_b

    hex32 = f"{uuid_int:032x}"
    return f"{hex32[0:8]}-{hex32[8:12]}-{hex32[12:16]}-{hex32[16:20]}-{hex32[20:32]}"


# ---------------------------
# NIK generator (realistic)
# ---------------------------
def generate_nik(gender: str) -> str:
    """
    NIK format (16 digit):
    - 6 digit kode wilayah
    - 6 digit tanggal lahir: ddmmyy (female: dd + 40)
    - 4 digit nomor urut
    """
    region = random.choice(NIK_REGION_CODES)

    # DOB range: 1970-2005 (realistic adult)
    year = random.randint(1970, 2005)
    month = random.randint(1, 12)
    # day safe
    day = random.randint(1, 28)

    if gender.lower() == "f":
        day += 40

    dob = f"{day:02d}{month:02d}{year % 100:02d}"
    seq = f"{random.randint(1, 9999):04d}"
    return f"{region}{dob}{seq}"


# ---------------------------
# Academic IDs (NRP/NIM)
# ---------------------------
def generate_student_number(level: str) -> str:
    """
    Petra NRP/NIM style example: C14210157 / A15220943
    We'll generate: <Letter><2 digits angkatan><2 digits prodi><4 digits urut>
    Total 1 + 8 = 9 chars.
    """
    letter = random.choice(list("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    angkatan = {"S1": random.randint(14, 23), "S2": random.randint(15, 25), "S3": random.randint(16, 26)}[level]
    prodi = random.randint(10, 99)
    urut = random.randint(1, 9999)
    return f"{letter}{angkatan:02d}{prodi:02d}{urut:04d}"


def generate_employee_number() -> str:
    """Simple NIP/Nomer Pegawai demo."""
    # 6-10 digits style
    length = random.choice([6, 7, 8, 9, 10])
    first = random.randint(1, 9)
    rest = "".join(str(random.randint(0, 9)) for _ in range(length - 1))
    return f"{first}{rest}"


def ldif_entry(
    dn: str,
    uid: str,
    cn: str,
    sn: str,
    given_name: str,
    display_name: str,
    mail: str,
    alt_mails: list[str],
    user_nik: Optional[str],
    affiliation: str,
    status: str,
    user_password_plain: str,
    student_number: Optional[str] = None,
    student_history: Optional[list[str]] = None,
    employee_number: Optional[str] = None,
) -> str:
    pw_hash = ssha_hash(user_password_plain)
    pw_b64 = b64_ldif_value(pw_hash)

    lines: list[str] = [
        f"dn: {dn}",
        "objectClass: inetOrgPerson",
        "objectClass: petraPerson",
        f"uid: {uid}",
        f"cn: {cn}",
        f"sn: {sn}",
        f"givenName: {given_name}",
        f"displayName: {display_name}",
        f"mail: {mail}",
    ]

    for a in alt_mails:
        lines.append(f"mailAlternateAddress: {a}")

    # New anchor identity
    if user_nik:
        lines.append(f"userNIK: {user_nik}")

    lines += [
        f"petraAffiliation: {affiliation}",
        f"petraAccountStatus: {status}",
    ]

    # Active student number (optional)
    if student_number:
        lines.append(f"studentNumber: {student_number}")

    # History (multi)
    if student_history:
        for h in student_history:
            lines.append(f"studentNumberHistory: {h}")

    # Employee number (optional)
    if employee_number:
        lines.append(f"employeeNumber: {employee_number}")
    
    lines.append(f"userPassword:: {pw_b64}")
    lines.append("")  # entry separator
    return "\n".join(lines)


def delete_ldif(dns: Iterable[str], comment: str) -> str:
    ts = datetime.now().isoformat(timespec="seconds")
    out = [f"# {comment}", f"# Generated: {ts}", "#"]
    seen: set[str] = set()
    for dn in dns:
        if dn in seen:
            continue
        seen.add(dn)
        out += [f"dn: {dn}", "changetype: delete", ""]
    return "\n".join(out)


def scenario_for_human(ou_key: str) -> tuple[Optional[str], Optional[list[str]], Optional[str]]:
    """
    Return (studentNumber_active, studentNumberHistory_list, employeeNumber)
    Based on various real-life scenarios:
    - S1 only
    - S2 only
    - S3 only
    - S2 while working
    - S1 while working
    - graduated S1 then working (active empty, history 1, employee 1)
    - staff only
    """
    if ou_key == "students":
        # Weighted scenarios for students
        pick = random.choices(
            population=[
                "S1_only",
                "S2_only",
                "S3_only",
                "S2_working",
                "S1_working",
            ],
            weights=[40, 20, 10, 15, 15],
            k=1
        )[0]

        if pick == "S1_only":
            active = generate_student_number("S1")
            return active, [], None

        if pick == "S2_only":
            # S2, maybe have S1 history or not
            active = generate_student_number("S2")
            history = [generate_student_number("S1")] if random.random() < 0.7 else []
            return active, history, None

        if pick == "S3_only":
            # S3 usually has S2 (and maybe S1) history
            active = generate_student_number("S3")
            history = [generate_student_number("S2")]
            if random.random() < 0.6:
                history.append(generate_student_number("S1"))
            return active, history, None

        if pick == "S2_working":
            active = generate_student_number("S2")
            history = [generate_student_number("S1")]  # minimal 1 history
            emp = generate_employee_number()
            return active, history, emp

        if pick == "S1_working":
            active = generate_student_number("S1")
            history = []  # still active S1
            emp = generate_employee_number()
            return active, history, emp

    if ou_key == "staff":
        # staff scenarios
        pick = random.choices(
            population=["staff_only", "ex_student_now_staff"],
            weights=[60, 40],
            k=1
        )[0]

        if pick == "staff_only":
            return None, [], generate_employee_number()

        # ex-student now staff: active studentNumber kosong, history 1, employee ada
        history = [generate_student_number(random.choice(["S1", "S2"]))]  # minimal 1 history
        return None, history, generate_employee_number()

    if ou_key == "alumni":
        # alumni: studentNumber aktif kosong, history biasanya ada 1
        history = [generate_student_number(random.choice(["S1", "S2", "S3"]))]
        return None, history, None

    # external
    return None, [], None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=20260216)
    ap.add_argument("--password", type=str, default="SeongJinWoo999!", help="plain password to hash into userPassword")
    ap.add_argument("--out", type=str, default="ldif/03-users.generated.ldif", help="output LDIF for ldapadd")
    ap.add_argument("--revert-out", type=str, default="ldif/05-revert-100.generated.ldif", help="output LDIF for ldapmodify delete")
    args = ap.parse_args()

    random.seed(args.seed)

    if len(HUMAN_FULLNAMES) != 50 or len(NONHUMAN_NAMES) != 50:
        raise SystemExit("Name lists must be exactly 50 each.")

    # account status (random but biased)
    statuses = (["active"] * 80) + (["disabled"] * 10) + (["suspended"] * 10)
    random.shuffle(statuses)
    sidx = 0

    # placement plan:
    # humans spread: students=30, staff=12, alumni=6, external=2
    # non-human: external=50
    human_plan = (["students"] * 30) + (["staff"] * 12) + (["alumni"] * 6) + (["external"] * 2)
    nonhuman_plan = (["external"] * 50)

    entries: list[str] = []
    dns: list[str] = []

    # Humans
    for full, ou_key in zip(HUMAN_FULLNAMES, human_plan):
        given, sn = split_two_words(full)
        cn = f"{given} {sn}"

        uid = uuid7_str()
        dn = f"uid={uid},{OU_DNS[ou_key]}"

        mail_local = slugify(f"{given}.{uid[:8]}")
        mail = build_mail(mail_local)

        handle = slugify(f"{given}.{sn}")
        alt_mails = build_mail_alternates(handle)

        gender = "f" if random.random() < 0.45 else "m"
        nik = generate_nik(gender)

        affiliation = {"students": "student", "staff": "staff", "alumni": "alumni", "external": "external"}[ou_key]

        student_active, student_hist, emp_no = scenario_for_human(ou_key)

        status = statuses[sidx]
        sidx += 1

        entries.append(ldif_entry(
            dn=dn,
            uid=uid,
            cn=cn,
            sn=sn,
            given_name=given,
            display_name=cn,
            mail=mail,
            alt_mails=alt_mails,
            user_nik=nik,
            affiliation=affiliation,
            status=status,
            user_password_plain=args.password,
            student_number=student_active,
            student_history=student_hist if student_hist else None,
            employee_number=emp_no,
        ))
        dns.append(dn)

    # Non-human (external service/vendor/org style)
    # Keep inetOrgPerson for consistent Keycloak mapper
    for name, ou_key in zip(NONHUMAN_NAMES, nonhuman_plan):
        given, sn = split_two_words(name)
        cn = f"{given} {sn}"

        uid = uuid7_str()
        dn = f"uid={uid},{OU_DNS[ou_key]}"

        mail_local = slugify(given)
        mail = build_mail(mail_local)

        handle = slugify(f"{given}.{sn}")
        alt_mails = build_mail_alternates(handle)

        status = statuses[sidx]
        sidx += 1

        # For non-human entries, we do NOT set userNIK (usually not applicable)
        entries.append(ldif_entry(
            dn=dn,
            uid=uid,
            cn=cn,
            sn=sn,
            given_name=given,
            display_name=cn,
            mail=mail,
            alt_mails=alt_mails,
            user_nik=None,
            affiliation="external",
            status=status,
            user_password_plain=args.password,
            student_number=None,
            student_history=None,
            employee_number=None,
        ))
        dns.append(dn)

    ts = datetime.now().isoformat(timespec="seconds")
    header = "\n".join([
        "# 03-users.generated.ldif",
        f"# Generated: {ts}",
        f"# Base DN: {BASE_DN}",
        "# Entities: 100 (50 human, 50 non-human)",
        "# uid: UUIDv7",
        "# userNIK: Indonesian NIK (16 digits, realistic format) for human entries",
        "# studentNumber: active NRP/NIM (optional)",
        "# studentNumberHistory: multi-value history (optional)",
        "# employeeNumber: optional (staff / working students scenarios)",
        "# mail domains: john.petra.ac.id / peter.petra.ac.id / petra.petra.ac.id (random)",
        "# mailAlternateAddress ALWAYS includes: alumni.petra.ac.id + google.com + yahoo.com + one-of john/peter/petra.petra.ac.id",
        "#",
    ])

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    os.makedirs(os.path.dirname(args.revert_out), exist_ok=True)

    with open(args.out, "w", encoding="utf-8") as f:
        f.write(header + "\n" + "\n".join(entries))

    with open(args.revert_out, "w", encoding="utf-8") as f:
        f.write(delete_ldif(dns, comment="05-revert-100.generated.ldif (DELETE the 100 generated entities)"))

    print(f"OK: wrote {args.out} and {args.revert_out}")
    print("UID: UUIDv7 for all entries")


if __name__ == "__main__":
    main()

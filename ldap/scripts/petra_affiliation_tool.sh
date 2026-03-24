#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s extglob

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/petra_affiliation.conf"

if [[ ! -f "${CONF_FILE}" ]]; then
  echo "ERROR: config file not found: ${CONF_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${CONF_FILE}"

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

for bin in ldapsearch ldapmodify awk sed grep mktemp sort tr flock; do
  require_bin "$bin"
done

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[INFO] $*" >&2
}

warn() {
  echo "[WARN] $*" >&2
}

normalize() {
  local v="${1:-}"
  v="$(echo "${v}" | tr '[:upper:]' '[:lower:]' | xargs)"
  echo "${v}"
}

is_allowed_affiliation() {
  local role
  role="$(normalize "${1:-}")"
  local x
  for x in "${ALLOWED_AFFILIATIONS[@]}"; do
    [[ "${role}" == "${x}" ]] && return 0
  done
  return 1
}

assert_allowed_affiliation() {
  local role
  role="$(normalize "${1:-}")"
  is_allowed_affiliation "${role}" || die "invalid affiliation: ${role}. allowed: ${ALLOWED_AFFILIATIONS[*]}"
}

ldapsearch_cmd() {
  ldapsearch -LLL -x -o ldif-wrap=no \
    -H "${LDAP_URI}" \
    -D "${BIND_DN}" \
    -y "${BIND_PW_FILE}" \
    "$@"
}

ldapmodify_cmd() {
  ldapmodify -x \
    -H "${LDAP_URI}" \
    -D "${BIND_DN}" \
    -y "${BIND_PW_FILE}" \
    "$@"
}

role_to_group_cn() {
  local role
  role="$(normalize "$1")"
  echo "${ROLE_GROUP_PREFIX}${role}"
}

dedupe_lines() {
  awk 'NF && !seen[$0]++'
}

resolve_user_dn() {
  local user="${1:-}"
  [[ -n "${user}" ]] || die "user is required"

  if [[ "${user}" == *",${BASE_DN}"* ]]; then
    echo "${user}"
    return 0
  fi

  local dn
  dn="$(
    ldapsearch_cmd \
      -b "${PEOPLE_BASE}" \
      "(&(objectClass=person)(|(uid=${user})(mail=${user})))" dn \
    | awk -F': ' '/^dn: /{print $2; exit}'
  )"

  [[ -n "${dn}" ]] || die "user not found: ${user}"
  echo "${dn}"
}

resolve_group_dn_by_role() {
  local role
  role="$(normalize "${1:-}")"
  assert_allowed_affiliation "${role}"

  local cn
  cn="$(role_to_group_cn "${role}")"

  local dn
  dn="$(
    ldapsearch_cmd \
      -b "${ROLE_GROUP_BASE}" \
      "(cn=${cn})" dn \
    | awk -F': ' '/^dn: /{print $2; exit}'
  )"

  [[ -n "${dn}" ]] || die "role group not found for role=${role}, expected cn=${cn} under ${ROLE_GROUP_BASE}"
  echo "${dn}"
}

get_primary_affiliation() {
  local user_dn="${1:-}"
  ldapsearch_cmd \
    -b "${user_dn}" \
    -s base \
    "(objectClass=*)" \
    petraAffiliation \
  | awk -F': ' '/^petraAffiliation: /{print $2; exit}' \
  | tr '[:upper:]' '[:lower:]'
}

get_alternate_affiliations() {
  local user_dn="${1:-}"
  ldapsearch_cmd \
    -b "${user_dn}" \
    -s base \
    "(objectClass=*)" \
    petraAlternateAffiliation \
  | awk -F': ' '/^petraAlternateAffiliation: /{print tolower($2)}' \
  | dedupe_lines
}

get_current_role_memberships() {
  local user_dn="${1:-}"

  ldapsearch_cmd \
    -b "${ROLE_GROUP_BASE}" \
    "(${GROUP_MEMBER_ATTR}=${user_dn})" \
    cn \
  | awk -F': ' '/^cn: /{print $2}' \
  | sed "s/^${ROLE_GROUP_PREFIX}//" \
  | tr '[:upper:]' '[:lower:]' \
  | dedupe_lines
}

pick_primary_by_priority() {
  local candidates=("$@")
  local c p

  for p in "${AFFILIATION_PRIORITY[@]}"; do
    for c in "${candidates[@]}"; do
      [[ "$(normalize "${c}")" == "$(normalize "${p}")" ]] && {
        echo "$(normalize "${p}")"
        return 0
      }
    done
  done

  if [[ "${#candidates[@]}" -gt 0 ]]; then
    echo "$(normalize "${candidates[0]}")"
    return 0
  fi

  return 1
}

sanitize_alt_list() {
  local primary
  primary="$(normalize "${1:-}")"
  shift || true

  local seen=()
  local role out=()

  for role in "$@"; do
    role="$(normalize "${role}")"
    [[ -n "${role}" ]] || continue
    is_allowed_affiliation "${role}" || die "invalid alternate affiliation: ${role}"

    [[ "${role}" == "${primary}" ]] && continue

    if [[ -z "${seen[${role}]:-}" ]]; then
      seen["${role}"]=1
      out+=("${role}")
    fi
  done

  printf '%s\n' "${out[@]}" 2>/dev/null || true
}

write_affiliations() {
  local user_dn="${1:-}"
  local primary="${2:-}"
  shift 2 || true

  primary="$(normalize "${primary}")"
  [[ -n "${primary}" ]] || die "primary affiliation cannot be empty"
  assert_allowed_affiliation "${primary}"

  local alts=()
  local cleaned
  while IFS= read -r cleaned; do
    [[ -n "${cleaned}" ]] && alts+=("${cleaned}")
  done < <(sanitize_alt_list "${primary}" "$@")

  local tmp_ldif
  tmp_ldif="$(mktemp)"

  {
    echo "dn: ${user_dn}"
    echo "changetype: modify"
    echo "replace: petraAffiliation"
    echo "petraAffiliation: ${primary}"
    echo "-"
    echo "delete: petraAlternateAffiliation"
    echo "-"
    if [[ "${#alts[@]}" -gt 0 ]]; then
      echo "add: petraAlternateAffiliation"
      local alt
      for alt in "${alts[@]}"; do
        echo "petraAlternateAffiliation: ${alt}"
      done
      echo "-"
    fi
  } > "${tmp_ldif}"

  ldapmodify_cmd -f "${tmp_ldif}" >/dev/null
  rm -f "${tmp_ldif}"

  log "updated affiliations for ${user_dn}: primary=${primary} alternate=${alts[*]:-<none>}"
}

ensure_member_of_role_group() {
  local user_dn="${1:-}"
  local role="${2:-}"

  role="$(normalize "${role}")"
  assert_allowed_affiliation "${role}"

  local group_dn
  group_dn="$(resolve_group_dn_by_role "${role}")"

  local tmp_ldif
  tmp_ldif="$(mktemp)"

  {
    echo "dn: ${group_dn}"
    echo "changetype: modify"
    echo "add: ${GROUP_MEMBER_ATTR}"
    echo "${GROUP_MEMBER_ATTR}: ${user_dn}"
  } > "${tmp_ldif}"

  if ! ldapmodify_cmd -f "${tmp_ldif}" >/dev/null 2>&1; then
    warn "membership may already exist: user=${user_dn} role=${role}"
  fi

  rm -f "${tmp_ldif}"
}

remove_member_of_role_group() {
  local user_dn="${1:-}"
  local role="${2:-}"

  role="$(normalize "${role}")"
  assert_allowed_affiliation "${role}"

  local group_dn
  group_dn="$(resolve_group_dn_by_role "${role}")"

  local tmp_ldif
  tmp_ldif="$(mktemp)"

  {
    echo "dn: ${group_dn}"
    echo "changetype: modify"
    echo "delete: ${GROUP_MEMBER_ATTR}"
    echo "${GROUP_MEMBER_ATTR}: ${user_dn}"
  } > "${tmp_ldif}"

  if ! ldapmodify_cmd -f "${tmp_ldif}" >/dev/null 2>&1; then
    warn "membership may already be absent: user=${user_dn} role=${role}"
  fi

  rm -f "${tmp_ldif}"
}

sync_exact_role_group_memberships() {
  local user_dn="${1:-}"
  shift || true

  local desired_roles=("$@")
  local current_roles=()
  local x

  while IFS= read -r x; do
    [[ -n "${x}" ]] && current_roles+=("${x}")
  done < <(get_current_role_memberships "${user_dn}")

  declare -A desired_map=()
  declare -A current_map=()

  for x in "${desired_roles[@]}"; do
    x="$(normalize "${x}")"
    [[ -n "${x}" ]] || continue
    desired_map["${x}"]=1
  done

  for x in "${current_roles[@]}"; do
    x="$(normalize "${x}")"
    [[ -n "${x}" ]] || continue
    current_map["${x}"]=1
  done

  for x in "${desired_roles[@]}"; do
    x="$(normalize "${x}")"
    [[ -n "${x}" ]] || continue
    if [[ -z "${current_map[${x}]:-}" ]]; then
      ensure_member_of_role_group "${user_dn}" "${x}"
    fi
  done

  if [[ "${EXACT_GROUP_SYNC}" == "true" ]]; then
    for x in "${current_roles[@]}"; do
      x="$(normalize "${x}")"
      [[ -n "${x}" ]] || continue
      if [[ -z "${desired_map[${x}]:-}" ]]; then
        remove_member_of_role_group "${user_dn}" "${x}"
      fi
    done
  fi
}

show_user() {
  local user_dn="${1:-}"
  echo "DN: ${user_dn}"
  echo "Primary: $(get_primary_affiliation "${user_dn}" || true)"
  echo "Alternate:"
  get_alternate_affiliations "${user_dn}" | sed 's/^/  - /' || true
  echo "Role groups:"
  get_current_role_memberships "${user_dn}" | sed 's/^/  - /' || true
}

cmd_show() {
  local user=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      *) die "unknown argument for show: $1" ;;
    esac
  done
  [[ -n "${user}" ]] || die "--user is required"
  local user_dn
  user_dn="$(resolve_user_dn "${user}")"
  show_user "${user_dn}"
}

cmd_set_primary() {
  local user=""
  local role=""
  local sync_groups="true"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      --role) role="$2"; shift 2 ;;
      --sync-groups) sync_groups="$2"; shift 2 ;;
      *) die "unknown argument for set-primary: $1" ;;
    esac
  done

  [[ -n "${user}" ]] || die "--user is required"
  [[ -n "${role}" ]] || die "--role is required"

  role="$(normalize "${role}")"
  assert_allowed_affiliation "${role}"

  local user_dn
  user_dn="$(resolve_user_dn "${user}")"

  local current_primary
  current_primary="$(get_primary_affiliation "${user_dn}" || true)"

  local current_alts=()
  local x
  while IFS= read -r x; do
    [[ -n "${x}" ]] && current_alts+=("${x}")
  done < <(get_alternate_affiliations "${user_dn}")

  local new_alts=()
  if [[ -n "${current_primary}" && "${current_primary}" != "${role}" ]]; then
    new_alts+=("${current_primary}")
  fi
  new_alts+=("${current_alts[@]}")

  write_affiliations "${user_dn}" "${role}" "${new_alts[@]}"

  if [[ "${sync_groups}" == "true" ]]; then
    local desired=("${role}" "${new_alts[@]}")
    sync_exact_role_group_memberships "${user_dn}" "${desired[@]}"
  fi
}

cmd_add_alternate() {
  local user=""
  local role=""
  local sync_groups="true"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      --role) role="$2"; shift 2 ;;
      --sync-groups) sync_groups="$2"; shift 2 ;;
      *) die "unknown argument for add-alternate: $1" ;;
    esac
  done

  [[ -n "${user}" ]] || die "--user is required"
  [[ -n "${role}" ]] || die "--role is required"

  role="$(normalize "${role}")"
  assert_allowed_affiliation "${role}"

  local user_dn
  user_dn="$(resolve_user_dn "${user}")"

  local current_primary
  current_primary="$(get_primary_affiliation "${user_dn}" || true)"

  if [[ -z "${current_primary}" ]]; then
    write_affiliations "${user_dn}" "${role}"
    [[ "${sync_groups}" == "true" ]] && sync_exact_role_group_memberships "${user_dn}" "${role}"
    return 0
  fi

  local current_alts=()
  local x
  while IFS= read -r x; do
    [[ -n "${x}" ]] && current_alts+=("${x}")
  done < <(get_alternate_affiliations "${user_dn}")

  current_alts+=("${role}")
  write_affiliations "${user_dn}" "${current_primary}" "${current_alts[@]}"

  if [[ "${sync_groups}" == "true" ]]; then
    local desired=("${current_primary}" "${current_alts[@]}")
    sync_exact_role_group_memberships "${user_dn}" "${desired[@]}"
  fi
}

cmd_remove_role() {
  local user=""
  local role=""
  local sync_groups="true"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      --role) role="$2"; shift 2 ;;
      --sync-groups) sync_groups="$2"; shift 2 ;;
      *) die "unknown argument for remove-role: $1" ;;
    esac
  done

  [[ -n "${user}" ]] || die "--user is required"
  [[ -n "${role}" ]] || die "--role is required"

  role="$(normalize "${role}")"
  assert_allowed_affiliation "${role}"

  local user_dn
  user_dn="$(resolve_user_dn "${user}")"

  local current_primary
  current_primary="$(get_primary_affiliation "${user_dn}" || true)"

  local current_alts=()
  local x
  while IFS= read -r x; do
    [[ -n "${x}" ]] && current_alts+=("${x}")
  done < <(get_alternate_affiliations "${user_dn}")

  local remaining=()
  local r
  if [[ -n "${current_primary}" && "${current_primary}" != "${role}" ]]; then
    remaining+=("${current_primary}")
  fi
  for r in "${current_alts[@]}"; do
    [[ "${r}" == "${role}" ]] && continue
    remaining+=("${r}")
  done

  [[ "${#remaining[@]}" -gt 0 ]] || die "cannot remove last affiliation; user must still have one primary affiliation"

  local new_primary
  new_primary="$(pick_primary_by_priority "${remaining[@]}")"

  local final_alts=()
  for r in "${remaining[@]}"; do
    [[ "$(normalize "${r}")" == "${new_primary}" ]] && continue
    final_alts+=("${r}")
  done

  write_affiliations "${user_dn}" "${new_primary}" "${final_alts[@]}"

  if [[ "${sync_groups}" == "true" ]]; then
    local desired=("${new_primary}" "${final_alts[@]}")
    sync_exact_role_group_memberships "${user_dn}" "${desired[@]}"
  fi
}

cmd_assign_role() {
  local user=""
  local role=""
  local primary_mode="auto"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      --role) role="$2"; shift 2 ;;
      --primary) primary_mode="$2"; shift 2 ;;
      *)
        die "unknown argument for assign-role: $1"
        ;;
    esac
  done

  [[ -n "${user}" ]] || die "--user is required"
  [[ -n "${role}" ]] || die "--role is required"

  role="$(normalize "${role}")"
  assert_allowed_affiliation "${role}"

  case "${primary_mode}" in
    true|false|auto) ;;
    *) die "--primary must be true|false|auto" ;;
  esac

  local user_dn
  user_dn="$(resolve_user_dn "${user}")"

  local current_primary
  current_primary="$(get_primary_affiliation "${user_dn}" || true)"

  if [[ "${primary_mode}" == "true" ]]; then
    cmd_set_primary --user "${user_dn}" --role "${role}" --sync-groups true
    return 0
  fi

  if [[ "${primary_mode}" == "false" ]]; then
    cmd_add_alternate --user "${user_dn}" --role "${role}" --sync-groups true
    return 0
  fi

  # auto
  if [[ -z "${current_primary}" ]]; then
    cmd_set_primary --user "${user_dn}" --role "${role}" --sync-groups true
  else
    cmd_add_alternate --user "${user_dn}" --role "${role}" --sync-groups true
  fi
}

cmd_sync_user() {
  local user=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      *) die "unknown argument for sync-user: $1" ;;
    esac
  done

  [[ -n "${user}" ]] || die "--user is required"
  local user_dn
  user_dn="$(resolve_user_dn "${user}")"

  local roles=()
  local x
  while IFS= read -r x; do
    [[ -n "${x}" ]] && roles+=("${x}")
  done < <(get_current_role_memberships "${user_dn}")

  [[ "${#roles[@]}" -gt 0 ]] || die "user has no role-group membership under ${ROLE_GROUP_BASE}: ${user_dn}"

  local primary
  primary="$(pick_primary_by_priority "${roles[@]}")"

  local alts=()
  for x in "${roles[@]}"; do
    [[ "$(normalize "${x}")" == "${primary}" ]] && continue
    alts+=("${x}")
  done

  write_affiliations "${user_dn}" "${primary}" "${alts[@]}"
}

cmd_sync_all() {
  local user_dns=()
  local dn

  while IFS= read -r dn; do
    [[ -n "${dn}" ]] && user_dns+=("${dn}")
  done < <(
    ldapsearch_cmd \
      -b "${PEOPLE_BASE}" \
      "(&(objectClass=person)(objectClass=petraPerson))" dn \
    | awk -F': ' '/^dn: /{print $2}'
  )

  [[ "${#user_dns[@]}" -gt 0 ]] || die "no users with objectClass=petraPerson found under ${PEOPLE_BASE}"

  local ok=0
  local fail=0
  for dn in "${user_dns[@]}"; do
    if cmd_sync_user --user "${dn}" >/dev/null 2>&1; then
      log "sync ok: ${dn}"
      ok=$((ok+1))
    else
      warn "sync failed: ${dn}"
      fail=$((fail+1))
    fi
  done

  echo "sync_all result: ok=${ok} fail=${fail}"
}

validate_one_user() {
  local user_dn="${1:-}"
  local primary
  primary="$(get_primary_affiliation "${user_dn}" || true)"

  local alts=()
  local x
  while IFS= read -r x; do
    [[ -n "${x}" ]] && alts+=("$(normalize "${x}")")
  done < <(get_alternate_affiliations "${user_dn}")

  local errors=()

  if [[ -z "${primary}" ]]; then
    errors+=("missing primary affiliation")
  else
    if ! is_allowed_affiliation "${primary}"; then
      errors+=("invalid primary affiliation: ${primary}")
    fi
  fi

  declare -A seen=()
  for x in "${alts[@]}"; do
    if ! is_allowed_affiliation "${x}"; then
      errors+=("invalid alternate affiliation: ${x}")
    fi
    if [[ -n "${primary}" && "${x}" == "${primary}" ]]; then
      errors+=("primary appears again in alternate: ${x}")
    fi
    if [[ -n "${seen[${x}]:-}" ]]; then
      errors+=("duplicate alternate affiliation: ${x}")
    fi
    seen["${x}"]=1
  done

  if [[ "${#errors[@]}" -eq 0 ]]; then
    echo "OK: ${user_dn}"
    return 0
  fi

  echo "BROKEN: ${user_dn}"
  printf '  - %s\n' "${errors[@]}"
  return 1
}

cmd_validate() {
  local user=""
  local fix="${AUTO_FIX_DEFAULT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      --fix) fix="$2"; shift 2 ;;
      *) die "unknown argument for validate: $1" ;;
    esac
  done

  case "${fix}" in
    true|false) ;;
    *) die "--fix must be true|false" ;;
  esac

  local targets=()
  if [[ -n "${user}" ]]; then
    targets+=("$(resolve_user_dn "${user}")")
  else
    local dn
    while IFS= read -r dn; do
      [[ -n "${dn}" ]] && targets+=("${dn}")
    done < <(
      ldapsearch_cmd \
        -b "${PEOPLE_BASE}" \
        "(&(objectClass=person)(objectClass=petraPerson))" dn \
      | awk -F': ' '/^dn: /{print $2}'
    )
  fi

  [[ "${#targets[@]}" -gt 0 ]] || die "no validation targets found"

  local ok=0
  local broken=0
  local dn

  for dn in "${targets[@]}"; do
    if validate_one_user "${dn}"; then
      ok=$((ok+1))
    else
      broken=$((broken+1))
      if [[ "${fix}" == "true" ]]; then
        warn "trying auto-fix via sync-user from role groups: ${dn}"
        if cmd_sync_user --user "${dn}" >/dev/null 2>&1; then
          log "auto-fix success: ${dn}"
        else
          warn "auto-fix failed: ${dn}"
        fi
      fi
    fi
  done

  echo "validate result: ok=${ok} broken=${broken}"
  [[ "${broken}" -eq 0 ]]
}

cmd_bulk_set() {
  local csv_file=""
  local sync_groups="true"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --csv) csv_file="$2"; shift 2 ;;
      --sync-groups) sync_groups="$2"; shift 2 ;;
      *) die "unknown argument for bulk-set: $1" ;;
    esac
  done

  [[ -n "${csv_file}" ]] || die "--csv is required"
  [[ -f "${csv_file}" ]] || die "csv file not found: ${csv_file}"

  local line_no=0
  local line user primary alternates_raw
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_no=$((line_no+1))
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^# ]] && continue

    IFS=',' read -r user primary alternates_raw <<< "${line}"

    user="$(echo "${user:-}" | xargs)"
    primary="$(echo "${primary:-}" | xargs)"
    alternates_raw="$(echo "${alternates_raw:-}" | xargs)"

    [[ -n "${user}" ]] || die "line ${line_no}: user is empty"
    [[ -n "${primary}" ]] || die "line ${line_no}: primary is empty"

    local user_dn
    user_dn="$(resolve_user_dn "${user}")"

    local alts=()
    if [[ -n "${alternates_raw}" ]]; then
      IFS='|' read -r -a alts <<< "${alternates_raw}"
    fi

    write_affiliations "${user_dn}" "${primary}" "${alts[@]}"

    if [[ "${sync_groups}" == "true" ]]; then
      local desired=("${primary}" "${alts[@]}")
      sync_exact_role_group_memberships "${user_dn}" "${desired[@]}"
    fi

    log "bulk-set ok line=${line_no} user=${user}"
  done < "${csv_file}"
}

usage() {
  cat <<'EOF'
Usage:
  petra_affiliation_tool.sh <command> [options]

Commands:
  show
    --user <uid|mail|dn>

  set-primary
    --user <uid|mail|dn>
    --role <student|staff|alumni|external>
    [--sync-groups true|false]

  add-alternate
    --user <uid|mail|dn>
    --role <student|staff|alumni|external>
    [--sync-groups true|false]

  remove-role
    --user <uid|mail|dn>
    --role <student|staff|alumni|external>
    [--sync-groups true|false]

  assign-role
    --user <uid|mail|dn>
    --role <student|staff|alumni|external>
    [--primary true|false|auto]

  sync-user
    --user <uid|mail|dn>

  sync-all

  validate
    [--user <uid|mail|dn>]
    [--fix true|false]

  bulk-set
    --csv <file.csv>
    [--sync-groups true|false]

CSV format for bulk-set:
  user,primary,alternate1|alternate2|alternate3

Examples:
  petra_affiliation_tool.sh show --user ani0001

  petra_affiliation_tool.sh set-primary \
    --user ani0001 \
    --role staff

  petra_affiliation_tool.sh add-alternate \
    --user ani0001 \
    --role student

  petra_affiliation_tool.sh assign-role \
    --user ani0001 \
    --role alumni \
    --primary false

  petra_affiliation_tool.sh remove-role \
    --user ani0001 \
    --role student

  petra_affiliation_tool.sh sync-user --user ani0001
  petra_affiliation_tool.sh sync-all
  petra_affiliation_tool.sh validate --fix true
EOF
}

main() {
  [[ -f "${BIND_PW_FILE}" ]] || die "bind password file not found: ${BIND_PW_FILE}"

  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || {
    usage
    exit 1
  }
  shift || true

  case "${cmd}" in
    show) cmd_show "$@" ;;
    set-primary) cmd_set_primary "$@" ;;
    add-alternate) cmd_add_alternate "$@" ;;
    remove-role) cmd_remove_role "$@" ;;
    assign-role) cmd_assign_role "$@" ;;
    sync-user) cmd_sync_user "$@" ;;
    sync-all) cmd_sync_all "$@" ;;
    validate) cmd_validate "$@" ;;
    bulk-set) cmd_bulk_set "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
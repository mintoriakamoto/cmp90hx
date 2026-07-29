#!/usr/bin/env bash
# Check all nine CMP90HX SM issue-rate modifiers on every detected GPU.
set -u -o pipefail

readonly root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly rm_query="${root_dir}/scripts/rm_issue_rate_query.py"
readonly per_gpu_timeout_seconds="${CMP90_CHECK_TIMEOUT_SECONDS:-15}"
declare -a bdfs=()
declare -A uuids=()
declare -A drivers=()
declare -A memories=()

die() {
    printf 'FAIL_CMP90HX_CHECK: %s\n' "$*" >&2
    exit 2
}

discover_cmp90_bdfs() {
    mapfile -t bdfs < <(
        for path in /sys/bus/pci/devices/*; do
            [[ -r "${path}/vendor" && -r "${path}/device" &&
               -r "${path}/subsystem_vendor" && -r "${path}/subsystem_device" ]] || continue
            [[ "$(<"${path}/vendor")" == 0x10de &&
               "$(<"${path}/device")" == 0x220d &&
               "$(<"${path}/subsystem_vendor")" == 0x10de &&
               "$(<"${path}/subsystem_device")" == 0x1555 ]] || continue
            basename "${path}"
        done | sort -V
    )
}

normalize_bdf() {
    local value="${1,,}"
    value="${value#00000000:}"
    printf '0000:%s\n' "${value#0000:}"
}

read_runtime_inventory() {
    local index bdf uuid memory driver normalized
    while IFS=',' read -r index bdf uuid memory driver; do
        normalized="$(normalize_bdf "${bdf// /}")"
        uuids["${normalized}"]="${uuid// /}"
        drivers["${normalized}"]="${driver// /}"
        memories["${normalized}"]="${memory// /}"
    done < <(
        nvidia-smi \
            --query-gpu=index,pci.bus_id,uuid,memory.total,driver_version \
            --format=csv,noheader,nounits
    )
}

render_rates() {
    python3 -c '
import json
import sys
rates = json.load(sys.stdin)["effective_issue_rates"]
order = ("dp", "ffma", "fmla16", "fmla32", "imla0", "imla1", "imla2", "imla3", "imla4")
labels = ("DP", "FFMA", "FMLA16", "FMLA32", "IMLA0", "IMLA1", "IMLA2", "IMLA3", "IMLA4")
print(" ".join("{}={}".format(label, rates[name]["rate"]) for name, label in zip(order, labels)))
'
}

[[ "${EUID}" -eq 0 ]] || die 'run as root'
[[ -f "${rm_query}" ]] || die "missing RM query helper: ${rm_query}"
command -v nvidia-smi >/dev/null || die 'nvidia-smi is unavailable'

discover_cmp90_bdfs
(( ${#bdfs[@]} > 0 )) || die 'no supported 10de:220d GPUs discovered'
read_runtime_inventory

failures=0
inconclusive=0
for bdf in "${bdfs[@]}"; do
    if [[ -z "${uuids[${bdf}]:-}" || -z "${drivers[${bdf}]:-}" || -z "${memories[${bdf}]:-}" ]]; then
        printf '%s FAIL missing from nvidia-smi\n' "${bdf}" >&2
        failures=$((failures + 1))
        continue
    fi

    if report="$(timeout "${per_gpu_timeout_seconds}" python3 "${rm_query}" \
        --bdf "${bdf}" \
        --uuid "${uuids[${bdf}]}" \
        --driver "${drivers[${bdf}]}" \
        --memory-mib "${memories[${bdf}]}" \
        --expect full 2>&1)"; then
        if details="$(render_rates <<<"${report}")"; then
            printf '%s PASS %s\n' "${bdf}" "${details}"
        else
            printf '%s FAIL could not render the 9 issue rates\n' "${bdf}" >&2
            failures=$((failures + 1))
        fi
    else
        query_status=$?
        if [[ "${query_status}" == 124 ]]; then
            printf '%s INCONCLUSIVE RM nine-rate query exceeded %ss; this is not a lock verdict\n' \
                "${bdf}" "${per_gpu_timeout_seconds}" >&2
            inconclusive=$((inconclusive + 1))
        else
            printf '%s FAIL unable to read all 9 issue rates: %s\n' \
                "${bdf}" "$(tail -n 1 <<<"${report}")" >&2
            failures=$((failures + 1))
        fi
    fi
done

if (( failures > 0 )); then
    printf 'FAIL_CMP90HX_NINE_RATE_CHECK (%s/%s GPU(s) failed)\n' \
        "${failures}" "${#bdfs[@]}" >&2
    exit 1
fi

if (( inconclusive > 0 )); then
    printf 'INCONCLUSIVE_CMP90HX_NINE_RATE_CHECK (%s/%s GPU(s) did not answer RM in time)\n' \
        "${inconclusive}" "${#bdfs[@]}" >&2
    exit 1
fi

printf 'PASS_CMP90HX_NINE_RATE_CHECK (%s GPU(s), 9 fields each)\n' "${#bdfs[@]}"

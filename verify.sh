#!/usr/bin/env bash
# Verify the completed persistent-service handoff without making RM private
# queries. Nine-rate inspection is intentionally left to standalone check.sh.
set -Eeuo pipefail

readonly batch_status='/run/cmp90hx-persistent-batch.status'
declare -a bdfs=()

[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }

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
(( ${#bdfs[@]} > 0 )) || { echo 'No supported CMP90HX GPUs found.' >&2; exit 1; }
systemctl is-active --quiet cmp90hx-persistent.service || {
    echo 'CMP90HX persistent service is not active/exited.' >&2
    exit 1
}
[[ -r "${batch_status}" ]] || { echo "Missing batch status: ${batch_status}" >&2; exit 1; }
grep -Fq "PASS all ${#bdfs[@]} CMP90HX GPUs completed" "${batch_status}" || {
    echo 'The batch status does not contain a complete success marker.' >&2
    exit 1
}

inventory="$(timeout 30 nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader)"
for bdf in "${bdfs[@]}"; do
    grep -Fqx "00000000:${bdf#0000:}" <<<"${inventory}" ||
        grep -Fqx "${bdf}" <<<"${inventory}" || {
            echo "GPU missing from nvidia-smi: ${bdf}" >&2
            exit 1
        }
done

printf 'PASS_CMP90HX_PERSISTENT_SERVICE (%s GPU(s))\n' "${#bdfs[@]}"

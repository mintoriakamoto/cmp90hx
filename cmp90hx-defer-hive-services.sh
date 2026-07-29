#!/usr/bin/env bash
# Keep HiveOS GPU consumers out of the bootstrap window, but always restore
# any service that was running before this wrapper entered.
set -u -o pipefail

readonly work="${CMP90_WORK_DIR:-/usr/local/lib/cmp90hx-persistent}"
readonly batch="${CMP90_BATCH_SCRIPT:-${work}/cmp90hx-batch.sh}"
readonly status="${CMP90_DEFER_STATUS_FILE:-/run/cmp90hx-persistent.status}"
readonly min_boot_seconds="${CMP90_MIN_BOOT_SECONDS:-0}"
readonly -a deferred_units=(hive.service os-core.service)
declare -a restore_units=()

log() {
    printf '%s cmp90hx-persistent: %s\n' "$(date -Is)" "$*" | tee -a "${status}"
}

unit_exists() {
    [[ "$(systemctl show --property=LoadState --value "$1" 2>/dev/null || true)" != not-found ]]
}

wait_for_boot_age() {
    local uptime_seconds wait_seconds
    [[ "${min_boot_seconds}" =~ ^[0-9]+$ ]] || {
        log 'FAIL invalid minimum boot age'
        exit 2
    }
    uptime_seconds="$(awk '{print int($1)}' /proc/uptime)"
    if (( uptime_seconds < min_boot_seconds )); then
        wait_seconds=$((min_boot_seconds - uptime_seconds))
        log "waiting ${wait_seconds}s for candidate-load boot timing"
        sleep "${wait_seconds}"
    fi
}

preflight_stock_driver() {
    local deadline=$((SECONDS + 180)) expected_count output bdf all_online
    local -a cmp90_bdfs=()
    mapfile -t cmp90_bdfs < <(for path in /sys/bus/pci/devices/*; do
        [[ -r "${path}/vendor" && -r "${path}/device" ]] || continue
        [[ "$(<"${path}/vendor")" == 0x10de &&
           "$(<"${path}/device")" == 0x220d &&
           "$(<"${path}/subsystem_vendor")" == 0x10de &&
           "$(<"${path}/subsystem_device")" == 0x1555 ]] || continue
        basename "${path}"
    done | sort -V)
    expected_count="${#cmp90_bdfs[@]}"
    (( expected_count > 0 )) || {
        log 'FAIL no supported CMP90HX GPUs discovered during stock preflight'
        return 1
    }

    # This happens only while the unmodified, on-disk vendor driver is active.
    # It establishes the observed GSP timing prerequisite before any candidate
    # module is inserted; no candidate-stage RM query is performed.
    modprobe nvidia 2>/dev/null || true
    log "stock-driver preflight waiting for ${expected_count} CMP90HX GPU(s)"
    while (( SECONDS < deadline )); do
        if output="$(timeout 15 nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null)"; then
            all_online=1
            for bdf in "${cmp90_bdfs[@]}"; do
                if ! grep -Fqx "00000000:${bdf#0000:}" <<<"${output}" &&
                   ! grep -Fqx "${bdf}" <<<"${output}"; then
                    all_online=0
                    break
                fi
            done
            if (( all_online == 1 )); then
                log "stock-driver preflight complete (${expected_count} CMP90HX GPU(s))"
                return 0
            fi
        fi
        sleep 2
    done
    log 'FAIL stock-driver preflight did not enumerate every CMP90HX GPU'
    return 1
}

restore_services() {
    local code="$?" index unit
    trap - EXIT HUP INT TERM
    for (( index=${#restore_units[@]} - 1; index >= 0; index-- )); do
        unit="${restore_units[index]}"
        if systemctl start --no-block "${unit}"; then
            log "restored ${unit}"
        else
            log "WARN could not restore ${unit}"
        fi
    done
    exit "${code}"
}

: >"${status}"
[[ -x "${batch}" ]] || { log "FAIL missing batch script ${batch}"; exit 1; }

wait_for_boot_age

for unit in "${deferred_units[@]}"; do
    unit_exists "${unit}" || continue
    if systemctl is-enabled --quiet "${unit}" 2>/dev/null ||
       systemctl is-active --quiet "${unit}"; then
        restore_units+=("${unit}")
    fi
    if systemctl is-active --quiet "${unit}"; then
        log "stopping active GPU consumer ${unit}"
        if systemctl stop "${unit}"; then
            :
        else
            log "WARN could not stop ${unit}; continuing because service ordering still applies"
        fi
    fi
done

trap restore_services EXIT HUP INT TERM
preflight_stock_driver || exit 1
"${batch}"

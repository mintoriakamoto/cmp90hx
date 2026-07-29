#!/usr/bin/env bash
# Unlock one CMP90HX through the verified in-driver V67 selector write and
# stock-driver handoff. All non-target CMP90HX GPUs are blocked from binding
# while the intentionally incomplete candidate module is loaded.
set -u -o pipefail

readonly work="${CMP90_WORK_DIR:-/usr/local/lib/cmp90hx-persistent}"
readonly install_dir="/lib/modules/$(uname -r)/updates/cmp90hx-persistent"
readonly candidate="${CMP90_CANDIDATE:-${install_dir}/nvidia.ko.bootstrap}"
readonly status="${CMP90_STATUS_FILE:-/run/cmp90hx-persistent-one.status}"
readonly log_file="${CMP90_LOG_FILE:-/run/cmp90hx-persistent-one.log}"
readonly target="${CMP90_TARGET_BDF:-0000:01:00.0}"
readonly post_candidate_reset="${CMP90_POST_CANDIDATE_RESET_METHOD:-bus}"
readonly candidate_settle_seconds="${CMP90_CANDIDATE_SETTLE_SECONDS:-2}"
declare -a bdfs=()

exec >"${log_file}" 2>&1
: >"${status}"

log() {
    printf '%s cmp90hx-persistent-one: %s\n' "$(date -Is)" "$*" | tee -a "${status}"
}

module_loaded() {
    lsmod | awk -v module="$1" '$1 == module { found = 1 } END { exit !found }'
}

discover_cmp90_bdfs() {
    mapfile -t bdfs < <(
        for path in /sys/bus/pci/devices/*; do
            [[ -r "${path}/vendor" && -r "${path}/device" ]] || continue
            [[ "$(<"${path}/vendor")" == 0x10de &&
               "$(<"${path}/device")" == 0x220d &&
               "$(<"${path}/subsystem_vendor")" == 0x10de &&
               "$(<"${path}/subsystem_device")" == 0x1555 ]] || continue
            basename "${path}"
        done | sort -V
    )
}

block_all_gpu_binds() {
    local bdf
    for bdf in "${bdfs[@]}"; do
        printf '%s\n' cmp90hx-skip >"/sys/bus/pci/devices/${bdf}/driver_override"
    done
}

allow_candidate_target() {
    # Both stock and candidate modules register the "nvidia" PCI driver.
    # The stock module has already been unloaded before this is written.
    printf '%s\n' nvidia >"/sys/bus/pci/devices/${target}/driver_override"
}

clear_overrides() {
    local bdf
    for bdf in "${bdfs[@]}"; do
        [[ -w "/sys/bus/pci/devices/${bdf}/driver_override" ]] &&
            printf '\n' >"/sys/bus/pci/devices/${bdf}/driver_override" || true
    done
}

bind_stock_gpus() {
    local bdf
    for bdf in "${bdfs[@]}"; do
        if [[ ! -L "/sys/bus/pci/devices/${bdf}/driver" ]]; then
            printf '%s' "${bdf}" > /sys/bus/pci/drivers/nvidia/bind || return 1
        fi
    done
}

unload_nvidia() {
    local attempt module all_unloaded
    pkill -x nvidia-smi 2>/dev/null || true
    systemctl stop nvidia-persistenced.service nvidia-powerd.service 2>/dev/null || true
    for attempt in $(seq 1 45); do
        for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
            module_loaded "${module}" && modprobe -r "${module}" 2>/dev/null || true
        done
        all_unloaded=1
        for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
            module_loaded "${module}" && all_unloaded=0
        done
        [[ "${all_unloaded}" == 1 ]] && return 0
        sleep 1
    done
    return 1
}

bus_reset_one() {
    local bdf="$1"
    local reset_method="/sys/bus/pci/devices/${bdf}/reset_method"

    [[ -w "${reset_method}" && -w "/sys/bus/pci/devices/${bdf}/reset" ]] ||
        return 1
    printf '%s\n' bus >"${reset_method}" || return 1
    printf 1 >"/sys/bus/pci/devices/${bdf}/reset"
}

bus_reset_all() {
    local bdf
    for bdf in "${bdfs[@]}"; do
        bus_reset_one "${bdf}" || return 1
    done
}

wait_all_cmp90_gpus() {
    local deadline=$((SECONDS + 180)) output bdf all_online
    while (( SECONDS < deadline )); do
        if output="$(timeout 15 nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null)"; then
            all_online=1
            for bdf in "${bdfs[@]}"; do
                if ! grep -Fqx "00000000:${bdf#0000:}" <<<"${output}" &&
                   ! grep -Fqx "${bdf}" <<<"${output}"; then
                    all_online=0
                    break
                fi
            done
            (( all_online == 1 )) && return 0
        fi
        sleep 2
    done
    return 1
}

recover() {
    local code="$?"
    trap - EXIT HUP INT TERM
    log "recovery code=${code}: restoring stock driver"
    pkill -x nvidia-smi 2>/dev/null || true
    unload_nvidia || true
    bus_reset_all || true
    sleep 4
    clear_overrides
    modprobe drm 2>/dev/null || true
    modprobe nvidia 2>/dev/null || true
    bind_stock_gpus || true
    exit "${code}"
}
trap recover EXIT HUP INT TERM

discover_cmp90_bdfs
(( ${#bdfs[@]} > 0 )) || { log 'FAIL no supported 10de:220d GPUs discovered'; exit 2; }
case " ${bdfs[*]} " in
    *" ${target} "*) ;;
    *) log "FAIL unsupported target ${target}"; exit 2 ;;
esac
[[ "${post_candidate_reset}" == bus ]] || { log 'FAIL only PCIe bus reset is supported'; exit 2; }
[[ "${candidate_settle_seconds}" =~ ^[0-9]+$ ]] || { log 'FAIL invalid candidate settle duration'; exit 2; }
[[ -f "${candidate}" ]] || {
    log 'FAIL candidate module missing'; exit 1;
}

log "begin target=${target}"
block_all_gpu_binds
unload_nvidia || { log 'FAIL cannot unload stock NVIDIA module'; exit 1; }
bus_reset_all || { log 'FAIL cannot bus-reset GPUs before candidate'; exit 1; }
sleep 4
allow_candidate_target
modprobe drm
modprobe ecc
insmod "${candidate}" \
    NVreg_OpenRmEnableUnsupportedGpus=1 \
    NVreg_EnableGpuFirmware=18 \
    NVreg_EnableGpuFirmwareLogs=2
# Trigger only the newly bound candidate node. Do not use nvidia-smi while
# the deliberately incomplete candidate is loaded: it would issue repeated RM
# queries during this short bootstrap phase. The candidate performs and reads
# back the compute-only selectors itself, before deliberately stopping RM.
log 'direct candidate loaded; triggering one bounded candidate device open'
timeout 5 python3 -c 'import os, time; fd = os.open("/dev/nvidia0", os.O_RDWR); time.sleep(0.1); os.close(fd)' \
    >/run/cmp90hx-persistent-one-trigger.log 2>&1 || true
log "candidate settle window=${candidate_settle_seconds}s"
sleep "${candidate_settle_seconds}"
unload_nvidia || { log 'FAIL cannot unload V67 candidate'; exit 1; }
[[ ! -e "/sys/bus/pci/devices/${target}/driver" ]] || {
    log 'FAIL direct candidate still owns target GPU'
    exit 1
}
log "direct candidate completed; post-candidate reset method=${post_candidate_reset} across all CMP90HX GPUs"
bus_reset_all || { log 'FAIL cannot bus-reset CMP90HX GPUs after selector step'; exit 1; }
# The candidate leaves shared PCIe/GSP state behind even though it bound only
# one target.  Reset every exact CMP90HX card again before the stock module
# probes the complete group.
sleep 8
bus_reset_all || { log 'FAIL cannot perform second bus reset after selector step'; exit 1; }
sleep 8
clear_overrides
modprobe nvidia
bind_stock_gpus || { log 'FAIL could not bind all GPUs to stock driver'; exit 1; }
wait_all_cmp90_gpus || { log 'FAIL stock handoff did not enumerate every CMP90HX GPU'; exit 1; }
log "PASS target=${target} direct selector write completed; stock handoff has every CMP90HX GPU"
exit 0

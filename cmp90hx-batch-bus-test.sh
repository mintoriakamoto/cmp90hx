#!/usr/bin/env bash
# Run the validated CMP90HX bootstrap sequentially for every supported card.
# The temporary candidate driver is loaded for exactly one target at a time.
set -u -o pipefail

readonly work="${CMP90_WORK_DIR:-/usr/local/lib/cmp90hx-persistent}"
readonly runner="${CMP90_RUNNER:-${work}/cmp90hx-one.sh}"
readonly install_dir="/lib/modules/$(uname -r)/updates/cmp90hx-persistent"
readonly candidate="${CMP90_CANDIDATE:-${install_dir}/nvidia.ko.bootstrap}"
readonly status="${CMP90_BATCH_STATUS_FILE:-/run/cmp90hx-persistent-batch.status}"
readonly first_candidate_settle_seconds="${CMP90_FIRST_CANDIDATE_SETTLE_SECONDS:-${CMP90_CANDIDATE_SETTLE_SECONDS:-2}}"
readonly subsequent_candidate_settle_seconds="${CMP90_SUBSEQUENT_CANDIDATE_SETTLE_SECONDS:-${CMP90_CANDIDATE_SETTLE_SECONDS:-2}}"
declare -a bdfs=()

log() {
    printf '%s cmp90hx-persistent-batch: %s\n' "$(date -Is)" "$*" | tee -a "${status}"
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

select_reset_method() {
    # The verified recovery path requires a PCIe bus reset for every card.
    # The exact 580.159.03 CMP90HX target exposes this method on each GPU.
    printf '%s\n' bus
}

: >"${status}"
[[ -x "${runner}" && -f "${candidate}" ]] || {
    log 'FAIL runner or candidate module missing'
    exit 1
}
[[ "${first_candidate_settle_seconds}" =~ ^[0-9]+$ &&
   "${subsequent_candidate_settle_seconds}" =~ ^[0-9]+$ ]] || {
    log 'FAIL invalid candidate settle duration'
    exit 2
}

discover_cmp90_bdfs
(( ${#bdfs[@]} > 0 )) || {
    log 'FAIL no supported 10de:220d/1555 GPUs discovered'
    exit 2
}

log "begin targets=${bdfs[*]} candidate=${candidate}"
for index in "${!bdfs[@]}"; do
    bdf="${bdfs[index]}"
    reset_method="$(select_reset_method "${bdf}")"
    if (( index == 0 )); then
        settle_seconds="${first_candidate_settle_seconds}"
    else
        settle_seconds="${subsequent_candidate_settle_seconds}"
    fi
    log "begin target=${bdf} reset_method=${reset_method} settle=${settle_seconds}s"
    if ! CMP90_TARGET_BDF="${bdf}" \
         CMP90_POST_CANDIDATE_RESET_METHOD="${reset_method}" \
         CMP90_CANDIDATE_SETTLE_SECONDS="${settle_seconds}" \
         CMP90_CANDIDATE="${candidate}" \
         CMP90_STATUS_FILE="/run/cmp90hx-persistent-one-${bdf}.status" \
         CMP90_LOG_FILE="/run/cmp90hx-persistent-one-${bdf}.log" \
         "${runner}"; then
        log "FAIL target=${bdf}; runner returned non-zero"
        exit 1
    fi
    if ! timeout 30 nvidia-smi -L >/dev/null 2>&1; then
        log "FAIL target=${bdf}; stock driver is not usable after handoff"
        exit 1
    fi
    log "PASS target=${bdf} stock_count=${#bdfs[@]}"
done

log "PASS all ${#bdfs[@]} CMP90HX GPUs completed"

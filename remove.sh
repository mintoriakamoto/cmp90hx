#!/usr/bin/env bash
# Remove only files owned by this project.  The normal installation never
# overwrites the vendor nvidia.ko; an old project-owned replacement is restored
# from the recorded backup as a compatibility rollback.
set -Eeuo pipefail

[[ "${1:-}" == '--yes' || "${1:-}" == '-y' ]] || {
    echo 'Run: sudo ./remove.sh --yes' >&2
    exit 1
}
[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }

readonly unit_name='cmp90hx-persistent.service'
readonly helper_dir='/usr/local/lib/cmp90hx-persistent'

systemctl disable --now "${unit_name}" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/${unit_name}"
rm -rf "${helper_dir}"
systemctl daemon-reload

for install_dir in /lib/modules/*/updates/cmp90hx-persistent; do
    [[ -d "${install_dir}" ]] || continue
    kernel="$(basename "$(dirname "$(dirname "${install_dir}")")")"
    backup="${install_dir}/backup/nvidia.ko.stock"
    candidate="${install_dir}/nvidia.ko.bootstrap"
    runtime_path_file="${install_dir}/runtime_module_path"
    if [[ -s "${backup}" && -s "${runtime_path_file}" ]]; then
        runtime_module="$(<"${runtime_path_file}")"
        [[ "${runtime_module}" == "/lib/modules/${kernel}/"* ]] || {
            echo "Refusing invalid recorded module path: ${runtime_module}" >&2
            exit 1
        }
        if [[ -f "${runtime_module}" && -f "${candidate}" ]] &&
           cmp -s "${runtime_module}" "${candidate}"; then
            install -m 0644 "${backup}" "${runtime_module}"
            echo "Restored legacy project-owned nvidia.ko at ${runtime_module}"
        fi
    fi
    rm -rf "${install_dir}"
    depmod -a "${kernel}"
done

echo 'CMP90HX persistent bootstrap removed. Reboot to continue with the stock driver only.'

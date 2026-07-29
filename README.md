# CMP90HX Persistent Compute Unlock - dev

This branch supports only CMP90HX \`10de:220d / 10de:1555\` with NVIDIA Open
Kernel Modules \`580.159.03\`. It does not unlock memory capacity, PCIe speed,
or any CMP170HX-specific feature.

\`install.sh\` downloads official source commit \`4dbb564094c7a73fe222b9b010d7782638643c65\`,
runs \`git apply --check\` for \`patches/0001-58015903-cmp90hx-direct-compute.patch\`,
then compiles the temporary candidate driver.

## Boot flow

The service enumerates exact cards, waits for the stock driver to see all of them,
and defers \`hive.service\` and \`os-core.service\` only while the batch runs. It then
processes one card at a time: the candidate writes and reads back the compute-only
selectors in the driver, all matching cards receive two PCIe \`bus\` resets, and the
untouched stock driver is reloaded and must enumerate every card. Deferred services
are restored on either success or failure.

The stock runtime \`nvidia.ko\` is never overwritten. The first install saves it under
\`/lib/modules/$(uname -r)/updates/cmp90hx-persistent/backup/nvidia.ko.stock\`.
Expect about two minutes per card. \`check.sh\` is standalone and never gates boot.

## Requirements

- systemd x86_64 Linux, exact CMP90HX IDs, NVIDIA **Open** \`580.159.03\`;
- matching headers at \`/lib/modules/$(uname -r)/build\`, Secure Boot disabled;
- PCIe \`bus\` available in each target GPU's \`reset_method\`;
- \`bash\`, GNU coreutils, \`make\`, \`gcc\`, \`ld\`, \`objcopy\`, \`git\`, \`patch\`,
  \`sha256sum\`, \`strings\`, \`install\`, \`modinfo\`, \`modprobe\`, \`insmod\`, \`depmod\`,
  \`nproc\`, \`python3\`, and \`timeout\`.

Debian/Ubuntu example: \`apt-get install -y build-essential git patch python3 linux-headers-$(uname -r)\`.
HiveOS can package its headers differently; the installer checks prerequisites.

## Install / verify / remove

\`\`\`bash
git clone --branch dev https://github.com/bendy2/cmp90hx.git
cd cmp90hx
sudo ./install.sh
sudo reboot
sudo ./verify.sh
sudo ./check.sh       # optional nine-field RM check
sudo ./remove.sh --yes  # then reboot to return to stock only
\`\`\`

Network access is required by this branch. \`CMP90_SOURCE_DIR=/path/to/source\` can
supply an offline, unmodified copy of the exact release.

On the six-card HiveOS validation host the formal boot completed
\`PASS all 6 CMP90HX GPUs completed\`, kept six GPUs online after every handoff,
and restored \`os-core.service\`.

\`main\` contains the same patch already applied to bundled source; its install has
no Git, network, or patch requirement.

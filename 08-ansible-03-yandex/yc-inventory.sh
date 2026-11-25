#!/usr/bin/env bash
# Print shell exports for prod.yml. Does not create or change cloud resources.
set -euo pipefail
scope=()
if [[ -n ${YC_LAB_FOLDER_ID:-} ]]; then scope=(--folder-id "$YC_LAB_FOLDER_ID"); fi
for pair in CH_HOST:clickhouse VECTOR_HOST:vector LH_HOST:lighthouse; do
  var=${pair%:*}
  vm="a08-${pair#*:}"
  data=$(yc compute instance get "$vm" "${scope[@]}" --format json)
  jq -e --arg vm "$vm" --arg folder "${YC_LAB_FOLDER_ID:-}" \
    '.status == "RUNNING" and .name == $vm and ($folder == "" or .folder_id == $folder)' \
    <<< "$data" >/dev/null || { echo "Проверьте каталог и состояние $vm (ожидается RUNNING)" >&2; exit 1; }
  addr=$(jq -er '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty' <<< "$data")
  printf 'export %s=%q\n' "$var" "$addr"
  if [[ $var == CH_HOST ]]; then
    private=$(jq -er '.network_interfaces[0].primary_v4_address.address // empty' <<< "$data")
    printf 'export CH_PRIVATE_IP=%q\n' "$private"
  fi
done

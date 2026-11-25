#!/usr/bin/env bash
# check: preview only; apply: preview + two real runs on three existing YC VMs.
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# != 2 || ( $1 != check && $1 != apply ) || -z ${2:-} ]]; then
  echo "Использование: bash test-yc.sh {check|apply} ID_КАТАЛОГА_YC" >&2
  exit 2
fi
mode=$1
export YC_LAB_FOLDER_ID="$2"
for cmd in yc jq git ansible ansible-lint ansible-playbook ansible-inventory awk; do
  command -v "$cmd" >/dev/null || { echo "Не найдена команда: $cmd" >&2; exit 1; }
done
active=$(yc config get folder-id)
[[ $active == "$YC_LAB_FOLDER_ID" ]] || { echo "Активный каталог YC не соответствует указанному. Остановка." >&2; exit 1; }
addresses=$(bash yc-inventory.sh)
eval "$addresses" # Values are shell-escaped with Bash printf %q by yc-inventory.sh.
[[ $CH_HOST != "$VECTOR_HOST" && $VECTOR_HOST != "$LH_HOST" && $CH_HOST != "$LH_HOST" ]] || {
  echo "В inventory должны быть три разных ВМ." >&2; exit 1;
}
umask 077
mkdir -p .local
out=$(mktemp -d ".local/yc-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
echo "Полные логи: $out"
export ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default
unset ANSIBLE_FORCE_COLOR
ansible-lint site.yml 2>&1 | tee "$out/lint.log"
ansible-playbook -i prod.yml site.yml --syntax-check
ansible-inventory -i prod.yml --graph
ansible all -i prod.yml -m ping
ansible all -i prod.yml -b -m command -a 'cloud-init status --wait'
{
  printf 'Environment: Yandex Cloud | Debian lab | %s UTC\n' "$(date -u +%F' '%T)"
  printf 'Commit: %s\n' "$(git rev-parse HEAD)"
  if [[ -n $(git status --porcelain -- .) ]]; then echo 'Warning: working tree has local changes'; fi
} > "$out/recap.txt"
run() {
  local label=$1 stable=$2
  shift 2
  ansible-playbook -i prod.yml site.yml "$@" 2>&1 | tee "$out/$label.log"
  printf '\n%s\n' "$label" >> "$out/recap.txt"
  awk -v stable="$stable" -f scripts/recap.awk "$out/$label.log" | tee -a "$out/recap.txt"
}
run check 0 --check --diff
if [[ $mode == apply ]]; then
  run first 0 --diff
  run second 1 --diff
  echo "Проверено: повторный запуск не изменил ни одного из трёх хостов."
fi
echo "Сводка: $out/recap.txt"

#!/usr/bin/env bash
# =============================================================================
#  Сетевая папка для Elasticsearch на Oracle Linux 9 (NFS-сервер)
#  Отключает SELinux, ставит nfs-utils, создаёт и публикует каталог /srv/es-data
#
#  Запуск:         sudo bash nfs_es_data.sh
#  С параметрами:  sudo NFS_CLIENTS=192.168.48.0/24 ES_UID=1000 bash nfs_es_data.sh
# =============================================================================
set -euo pipefail

# ----------------------------- Параметры -------------------------------------
ES_DIR="${ES_DIR:-/srv/es-data}"                 # каталог, который отдаём по сети
NFS_CLIENTS="${NFS_CLIENTS:-192.168.48.0/24}"    # кому разрешён доступ (подсеть или IP)
ES_UID="${ES_UID:-1000}"                         # UID пользователя elasticsearch
ES_GID="${ES_GID:-1000}"                         # GID пользователя elasticsearch
DISABLE_FIREWALLD="${DISABLE_FIREWALLD:-true}"   # как на остальных серверах

# ----------------------------- Служебное -------------------------------------
log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите скрипт от root: sudo bash $0"

# ----------------------------- 1. SELinux ------------------------------------
# Отключаем ДО установки пакетов и служб, чтобы метки SELinux не мешали NFS
log "1. Полное отключение SELinux"
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
grubby --update-kernel ALL --args selinux=0
echo "Текущий режим: $(getenforce 2>/dev/null || echo unknown)"

# ----------------------------- 2. Файрвол ------------------------------------
if [[ "$DISABLE_FIREWALLD" == "true" ]]; then
  log "2. Отключение firewalld"
  systemctl disable --now firewalld 2>/dev/null || true
  systemctl mask firewalld 2>/dev/null || true
else
  log "2. firewalld оставлен: откройте порт 2049/tcp вручную"
fi

# ----------------------------- 3. Пакеты -------------------------------------
log "3. Установка nfs-utils"
# sssd-nfs-idmap нужен только для сопоставления имён через SSSD и в зеркале клиента
# отсутствует, поэтому сначала пробуем без необязательных зависимостей.
if ! dnf -y install --setopt=install_weak_deps=False nfs-utils; then
  warn "dnf не смог установить nfs-utils — ставлю пакеты через rpm --nodeps"
  mkdir -p /tmp/nfs-rpm
  dnf download --resolve --alldeps --destdir /tmp/nfs-rpm \
    --exclude=sssd-nfs-idmap nfs-utils || true
  ls /tmp/nfs-rpm/*.rpm >/dev/null 2>&1 || die "Не удалось скачать пакеты nfs-utils"
  rpm -Uvh --nodeps /tmp/nfs-rpm/*.rpm
  grep -q '^exclude=' /etc/dnf/dnf.conf \
    || echo 'exclude=sssd-nfs-idmap' >> /etc/dnf/dnf.conf
fi

# ----------------------------- 4. Каталог ------------------------------------
log "4. Каталог $ES_DIR"
mkdir -p "$ES_DIR"
chown "${ES_UID}:${ES_GID}" "$ES_DIR"
chmod 0775 "$ES_DIR"
ls -ld "$ES_DIR"

# ----------------------------- 5. Публикация по NFS --------------------------
log "5. Публикация каталога для $NFS_CLIENTS"
EXPORT_LINE="$ES_DIR ${NFS_CLIENTS}(rw,sync,no_subtree_check,no_root_squash)"
if grep -qF "$ES_DIR " /etc/exports 2>/dev/null; then
  echo "Запись для $ES_DIR уже есть в /etc/exports — пропускаю"
else
  echo "$EXPORT_LINE" >> /etc/exports
fi

systemctl enable --now nfs-server
exportfs -rav

# ----------------------------- Итог ------------------------------------------
log "Готово. Опубликованные каталоги:"
exportfs -v
echo
echo "На сервере Elasticsearch выполните:"
echo "  dnf -y install nfs-utils"
echo "  mkdir -p /mnt/es-data"
echo "  echo '$(hostname -I | awk '{print $1}'):${ES_DIR} /mnt/es-data nfs4 defaults,_netdev,hard,timeo=600,retrans=2 0 0' >> /etc/fstab"
echo "  mount -a && df -h /mnt/es-data"

warn "Перезагрузите сервер (reboot), чтобы SELinux отключился полностью"

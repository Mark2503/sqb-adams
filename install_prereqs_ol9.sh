#!/usr/bin/env bash
# =============================================================================
#  Подготовка Oracle Linux Server 9.x к развертыванию Directum RX
#  Docker Engine + Buildx 0.30.1 + Compose 2.40.3, PostgreSQL, системные пакеты
#
#  Запуск:            sudo bash install_prereqs_ol9.sh
#  С параметрами:     sudo PG_VERSION=17 bash install_prereqs_ol9.sh
# =============================================================================
set -euo pipefail

# ----------------------------- Параметры -------------------------------------
PG_VERSION="${PG_VERSION:-16}"                   # поддерживаются 11–18
PG_LOCALE="${PG_LOCALE:-ru_RU.UTF-8}"            # локаль кластера PostgreSQL при initdb
DOCKER_VERSION="${DOCKER_VERSION:-}"             # пусто = последняя; например 28.5.2
BUILDX_VERSION="${BUILDX_VERSION:-0.30.1}"
COMPOSE_VERSION="${COMPOSE_VERSION:-2.40.3}"
REPLACE_FIREWALLD="${REPLACE_FIREWALLD:-true}"   # firewalld -> iptables (аналог удаления ufw)
DOCKER_USER="${DOCKER_USER:-${SUDO_USER:-}}"     # кого добавить в группу docker
# Прокси для Docker: по умолчанию берётся из /etc/dnf/dnf.conf или переменной https_proxy.
# Пусто = без прокси. Частные сети (внутренние адреса) идут напрямую.
DNF_PROXY="$(sed -n 's/^proxy[[:space:]]*=[[:space:]]*//p' /etc/dnf/dnf.conf 2>/dev/null | head -1)"
DOCKER_PROXY="${DOCKER_PROXY:-${https_proxy:-${HTTPS_PROXY:-$DNF_PROXY}}}"
DOCKER_NO_PROXY="${DOCKER_NO_PROXY:-localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"

# ----------------------------- Служебное -------------------------------------
log()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите скрипт от root: sudo bash $0"

. /etc/os-release
if [[ "${ID:-}" != "ol" || "${VERSION_ID%%.*}" != "9" ]]; then
  warn "Скрипт рассчитан на Oracle Linux 9, обнаружено: ${PRETTY_NAME:-unknown}"
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  BUILDX_ARCH="amd64"; COMPOSE_ARCH="x86_64"  ;;
  aarch64) BUILDX_ARCH="arm64"; COMPOSE_ARCH="aarch64" ;;
  *) die "Неподдерживаемая архитектура: $ARCH" ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ----------------------------- 1. Базовые пакеты -----------------------------
# unzip, cifs-utils          — как в исходном скрипте
# libicu                     — аналог libicu70
# compat-openssl11           — аналог libssl1.1 (без хака с impish-security)
log "1. Базовые пакеты"
dnf -y install dnf-plugins-core
dnf -y makecache
dnf -y install \
  unzip tar curl ca-certificates gnupg2 \
  cifs-utils \
  libicu \
  compat-openssl11 \
  glibc-langpack-ru glibc-langpack-en

# ----------------------------- 2. Файрвол ------------------------------------
if [[ "$REPLACE_FIREWALLD" == "true" ]]; then
  log "2. firewalld -> iptables (аналог 'apt purge ufw' + iptables-persistent)"
  if ! systemctl is-enabled -q iptables 2>/dev/null; then
    systemctl disable --now firewalld 2>/dev/null || true
    systemctl mask firewalld 2>/dev/null || true
    dnf -y install iptables-nft-services || dnf -y install iptables-services
    # Сохраняем текущие (пустые) правила. Иначе iptables.service при старте
    # загрузит правила по умолчанию, которые блокируют всё, кроме SSH.
    iptables-save  > /etc/sysconfig/iptables
    ip6tables-save > /etc/sysconfig/ip6tables
    systemctl enable iptables ip6tables
  else
    echo "iptables.service уже включён — пропускаю"
  fi
else
  log "2. firewalld оставлен без изменений"
fi

# ----------------------------- 3. SELinux ------------------------------------
log "3. Полное отключение SELinux (container-selinux не используется)"
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
grubby --update-kernel ALL --args selinux=0

# ----------------------------- 4. Docker Engine ------------------------------
log "4. Docker Engine"
if ! rpm -q docker-ce &>/dev/null; then
  # В OL9 могут стоять podman/buildah/runc — они конфликтуют с containerd.io
  dnf -y remove docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-engine \
    podman podman-docker buildah runc 2>/dev/null || true
fi

dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

if [[ -n "$DOCKER_VERSION" ]]; then
  DOCKER_PKGS=("docker-ce-${DOCKER_VERSION}*" "docker-ce-cli-${DOCKER_VERSION}*")
else
  DOCKER_PKGS=(docker-ce docker-ce-cli)
fi

# Без weak deps: buildx/compose ставим ниже в точных версиях с GitHub
if rpm -q docker-ce &>/dev/null; then
  echo "Docker уже установлен: $(rpm -q docker-ce) — пропускаю"
elif ! dnf -y install --setopt=install_weak_deps=False "${DOCKER_PKGS[@]}" containerd.io; then
  # SELinux отключён, но docker-ce всё равно требует пакет container-selinux.
  # Если он не скачивается (битое зеркало) — ставим Docker через rpm без этой зависимости.
  warn "dnf не смог установить Docker — ставлю через rpm --nodeps"
  mkdir -p "$TMP_DIR/docker-rpm"
  dnf download --disableexcludes=all --destdir "$TMP_DIR/docker-rpm" "${DOCKER_PKGS[@]}" containerd.io
  rpm -Uvh --nodeps "$TMP_DIR"/docker-rpm/*.rpm
  # чтобы dnf update не падал из-за отсутствующего container-selinux
  grep -q '^exclude=' /etc/dnf/dnf.conf \
    || echo 'exclude=container-selinux docker-ce docker-ce-cli containerd.io' >> /etc/dnf/dnf.conf
fi
if [[ -n "$DOCKER_PROXY" ]]; then
  echo "Прокси для Docker: $DOCKER_PROXY"
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${DOCKER_PROXY}"
Environment="HTTPS_PROXY=${DOCKER_PROXY}"
Environment="NO_PROXY=${DOCKER_NO_PROXY}"
EOF
  systemctl daemon-reload
fi
systemctl enable containerd docker
systemctl restart containerd docker

if [[ -n "$DOCKER_USER" && "$DOCKER_USER" != "root" ]]; then
  usermod -aG docker "$DOCKER_USER"
  echo "Пользователь $DOCKER_USER добавлен в группу docker (нужен перелогин)"
fi

# ----------------------------- 5. Buildx и Compose ---------------------------
log "5. Docker Buildx ${BUILDX_VERSION} и Docker Compose ${COMPOSE_VERSION}"

# Если ранее ставились RPM-плагины — убираем, чтобы не было двух версий
for p in docker-buildx-plugin docker-compose-plugin; do
  rpm -q "$p" &>/dev/null && dnf -y remove "$p"
done

PLUGIN_DIR=/usr/local/lib/docker/cli-plugins
mkdir -p "$PLUGIN_DIR"

# $1 — URL каталога релиза, $2 — имя файла, $3 — файл контрольных сумм, $4 — итоговое имя
install_plugin() {
  local base="$1" file="$2" sums="$3" target="$4"
  curl -fsSL --retry 3 -o "$TMP_DIR/$file" "$base/$file"
  curl -fsSL --retry 3 -o "$TMP_DIR/$sums" "$base/$sums"
  ( cd "$TMP_DIR" && grep -E " \*?${file}\$" "$sums" | sha256sum -c - ) \
    || die "Контрольная сумма $file не совпала"
  install -m 0755 "$TMP_DIR/$file" "$PLUGIN_DIR/$target"
}

install_plugin \
  "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}" \
  "buildx-v${BUILDX_VERSION}.linux-${BUILDX_ARCH}" "checksums.txt" "docker-buildx"

install_plugin \
  "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}" \
  "docker-compose-linux-${COMPOSE_ARCH}" "docker-compose-linux-${COMPOSE_ARCH}.sha256" "docker-compose"

# ----------------------------- 6. PostgreSQL ---------------------------------
log "6. PostgreSQL ${PG_VERSION} (репозиторий PGDG)"
if ! rpm -q pgdg-redhat-repo &>/dev/null; then
  dnf -y install "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-${ARCH}/pgdg-redhat-repo-latest.noarch.rpm"
fi
dnf -qy module disable postgresql 2>/dev/null || true

dnf -y install \
  "postgresql${PG_VERSION}" \
  "postgresql${PG_VERSION}-server" \
  "postgresql${PG_VERSION}-contrib"

PGDATA="/var/lib/pgsql/${PG_VERSION}/data"
if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
  PGSETUP_INITDB_OPTIONS="-E UTF8 --locale=${PG_LOCALE}" \
    "/usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup" initdb
else
  echo "Кластер уже инициализирован в $PGDATA — пропускаю initdb"
fi
systemctl enable --now "postgresql-${PG_VERSION}"

# ----------------------------- 7. sysctl -------------------------------------
log "7. vm.max_map_count для Elasticsearch"
echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-directum.conf
sysctl --system >/dev/null
sysctl vm.max_map_count

# ----------------------------- Итог ------------------------------------------
log "Готово. Установленные версии:"
docker --version
docker buildx version
docker compose version
docker info 2>/dev/null | grep -i proxy || echo "Docker работает без прокси"
"/usr/pgsql-${PG_VERSION}/bin/psql" --version
systemctl is-active docker "postgresql-${PG_VERSION}"
warn "Перезагрузите сервер (reboot), чтобы SELinux отключился полностью"

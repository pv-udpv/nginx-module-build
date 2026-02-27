#!/bin/bash
# compile-nginx-modules.sh
# Compiles NDK + set_misc + geoip2 as dynamic modules
# for the nginx.org Nginx on Ubuntu Noble (24.04)
#
# Usage: sudo bash compile-nginx-modules.sh
#
# Modules built:
#   - ngx_devel_kit          (NDK)
#   - set-misc-nginx-module  (requires NDK)
#   - ngx_http_geoip2_module (requires libmaxminddb)
#
# Strategy:
#   1. Auto-detect nginx version + configure flags via `nginx -V`
#   2. Download matching nginx sources from nginx.org
#   3. Clone module sources (latest stable)
#   4. `make modules` — only .so files, no binary rebuild
#   5. Install .so → /usr/lib/nginx/modules/
#   6. Restore load_module directives in nginx.conf
#   7. nginx -t && systemctl start nginx

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}▶ $*${NC}"; }
ok()    { echo -e "${GREEN}✅ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $*${NC}"; }
die()   { echo -e "${RED}❌ $*${NC}"; exit 1; }

# ── Sanity checks ────────────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && die "Requires root. Run: sudo bash $0"
command -v nginx &>/dev/null || die "nginx not found in PATH"

# ── Detect nginx version + build flags ───────────────────────────────────────
NGINX_VER=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
NGINX_BUILD_FLAGS=$(nginx -V 2>&1 | sed 's/.*configure arguments://')
MODULE_DIR="/usr/lib/nginx/modules"
WORK_DIR="/tmp/nginx-modules-build-${NGINX_VER}"

info "Nginx version: ${NGINX_VER}"
info "Module dir:    ${MODULE_DIR}"
info "Work dir:      ${WORK_DIR}"
echo ""

# ── Build dependencies ───────────────────────────────────────────────────────
info "Installing build dependencies..."
apt-get install -y --no-install-recommends \
    build-essential git wget \
    libpcre3-dev libssl-dev zlib1g-dev \
    libmaxminddb-dev \
    libluajit-5.1-dev \
    dpkg-dev 2>&1 | grep -E '(Setting up|already installed)' || true
ok "Dependencies ready"
echo ""

# ── Prepare work directory ───────────────────────────────────────────────────
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# ── Download nginx sources ───────────────────────────────────────────────────
info "Downloading nginx-${NGINX_VER} sources..."
wget -q --show-progress "http://nginx.org/download/nginx-${NGINX_VER}.tar.gz"
tar -xzf "nginx-${NGINX_VER}.tar.gz"
ok "nginx sources ready"
echo ""

# ── Clone module sources ─────────────────────────────────────────────────────
info "Cloning module sources..."

git clone -q --depth=1 https://github.com/vision5/ngx_devel_kit.git
NDK_VER=$(git -C ngx_devel_kit describe --tags 2>/dev/null || git -C ngx_devel_kit rev-parse --short HEAD)
ok "ngx_devel_kit       @ ${NDK_VER}"

git clone -q --depth=1 https://github.com/openresty/set-misc-nginx-module.git
SMV=$(git -C set-misc-nginx-module describe --tags 2>/dev/null || git -C set-misc-nginx-module rev-parse --short HEAD)
ok "set-misc-nginx-module @ ${SMV}"

git clone -q --depth=1 https://github.com/leev/ngx_http_geoip2_module.git
GEO_VER=$(git -C ngx_http_geoip2_module describe --tags 2>/dev/null || git -C ngx_http_geoip2_module rev-parse --short HEAD)
ok "ngx_http_geoip2_module @ ${GEO_VER}"
echo ""

# ── Configure + make modules ─────────────────────────────────────────────────
info "Running ./configure..."
cd "nginx-${NGINX_VER}"

# Append our dynamic modules to the original configure flags
# shellcheck disable=SC2086
./configure ${NGINX_BUILD_FLAGS} \
    --add-dynamic-module=../ngx_devel_kit \
    --add-dynamic-module=../set-misc-nginx-module \
    --add-dynamic-module=../ngx_http_geoip2_module \
    > /tmp/nginx-configure.log 2>&1 || {
      echo "Configure failed! Last 20 lines:"
      tail -20 /tmp/nginx-configure.log
      die "Configure failed"
    }
ok "Configure successful"

echo ""
info "Compiling modules (make -j$(nproc) modules)..."
make -j"$(nproc)" modules > /tmp/nginx-make.log 2>&1 || {
  echo "Make failed! Last 20 lines:"
  tail -20 /tmp/nginx-make.log
  die "Compilation failed"
}
ok "Compilation successful"
echo ""

# ── Verify built .so files ───────────────────────────────────────────────────
for so in ndk_http_module.so ngx_http_set_misc_module.so ngx_http_geoip2_module.so; do
  [ -f "objs/${so}" ] || die "Expected ${so} not found in objs/"
done
ok "All 3 .so files built"
echo ""

# ── Backup old modules ───────────────────────────────────────────────────────
info "Backing up old modules..."
BACKUP_DIR="${MODULE_DIR}/backup-v$(date +%Y%m%d%H%M%S)"
mkdir -p "${BACKUP_DIR}"
for so in ndk_http_module.so ngx_http_set_misc_module.so ngx_http_geoip2_module.so; do
  if [ -f "${MODULE_DIR}/${so}" ]; then
    cp "${MODULE_DIR}/${so}" "${BACKUP_DIR}/"
    echo "  backed up: ${so}"
  fi
done
ok "Old modules saved to ${BACKUP_DIR}"
echo ""

# ── Install new modules ──────────────────────────────────────────────────────
info "Installing new modules to ${MODULE_DIR}..."
install -m644 objs/ndk_http_module.so              "${MODULE_DIR}/ndk_http_module.so"
install -m644 objs/ngx_http_set_misc_module.so     "${MODULE_DIR}/ngx_http_set_misc_module.so"
install -m644 objs/ngx_http_geoip2_module.so       "${MODULE_DIR}/ngx_http_geoip2_module.so"
for so in ndk_http_module.so ngx_http_set_misc_module.so ngx_http_geoip2_module.so; do
  SIZE=$(stat -c%s "${MODULE_DIR}/${so}")
  echo "  ✅ ${so} (${SIZE} bytes)"
done
ok "Modules installed"
echo ""

# ── Restore nginx.conf load_module directives ────────────────────────────────
info "Restoring load_module directives in nginx.conf..."
NGINX_CONF="/etc/nginx/nginx.conf"

# Uncomment lines previously disabled (handles both '# loadmodule' and '# load_module ... # v1.28.0')
sed -i \
  -e 's|^# \(load_module.*ndk_http_module\.so[^;]*;\).*|\1|' \
  -e 's|^# \(load_module.*ngx_http_set_misc_module\.so[^;]*;\).*|\1|' \
  -e 's|^# \(load_module.*ngx_http_geoip2_module\.so[^;]*;\).*|\1|' \
  "${NGINX_CONF}"

# Restore geoip2 directives (remove '# DISABLED' suffix/prefix)
sed -i 's|^# \(.*geoip2.*\) # DISABLED.*|\1|' "${NGINX_CONF}"
sed -i 's|^# \(.*geoip2\b.*\)|\1|' "${NGINX_CONF}"

ok "nginx.conf restored"
echo ""

# ── Final nginx -t + start ───────────────────────────────────────────────────
info "Testing nginx configuration..."
if nginx -t 2>&1; then
  ok "Config is valid!"
  echo ""
  info "Starting nginx..."
  systemctl start nginx.service
  sleep 1

  if systemctl is-active --quiet nginx.service; then
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✅  nginx ${NGINX_VER} + ALL MODULES RUNNING  ✅${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    nginx -V 2>&1 | head -2
    echo ""
    echo "Active load_module directives:"
    grep "^load_module" "${NGINX_CONF}"
    echo ""
    systemctl status nginx.service --no-pager -l | head -8
  else
    warn "nginx started but is not active. Check: journalctl -xeu nginx.service"
    exit 1
  fi
else
  warn "nginx -t failed after module install. Manual fix required:"
  echo ""
  echo "  nginx -t 2>&1          # see exact error"
  echo "  nano ${NGINX_CONF}     # edit config"
  echo "  Rollback: cp ${BACKUP_DIR}/*.so ${MODULE_DIR}/"
  exit 1
fi

# ── Cleanup ──────────────────────────────────────────────────────────────────
echo ""
info "Cleaning up ${WORK_DIR}..."
rm -rf "${WORK_DIR}"
ok "Done. Backup at: ${BACKUP_DIR}"

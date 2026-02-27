# nginx-module-build

Auto-compiles **NDK + set_misc + GeoIP2** dynamic modules for [nginx.org](https://nginx.org) Nginx on **Ubuntu Noble 24.04**.

## Problem

`nginx.org` ships Nginx without third-party dynamic modules. When Nginx is upgraded (e.g. `1.28.0 → 1.28.2`), manually-compiled `.so` files become incompatible:

```
nginx: [emerg] module "/etc/nginx/modules/ndk_http_module.so"
       version 1028000 instead of 1028002
```

This script recompiles all three modules to match the installed Nginx version — automatically.

## Modules compiled

| Module | Source | Notes |
|--------|--------|-------|
| `ngx_devel_kit` | [vision5/ngx_devel_kit](https://github.com/vision5/ngx_devel_kit) | Required by set_misc |
| `set-misc-nginx-module` | [openresty/set-misc-nginx-module](https://github.com/openresty/set-misc-nginx-module) | Depends on NDK |
| `ngx_http_geoip2_module` | [leev/ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module) | Requires `libmaxminddb` |

## Usage

```bash
# Download and run
wget https://raw.githubusercontent.com/pv-udpv/nginx-module-build/main/compile-nginx-modules.sh
sudo bash compile-nginx-modules.sh
```

Or clone the repo:

```bash
git clone https://github.com/pv-udpv/nginx-module-build.git
sudo bash nginx-module-build/compile-nginx-modules.sh
```

## What it does

1. **Detects** installed nginx version + original `configure` flags via `nginx -V`
2. **Downloads** matching nginx sources from `nginx.org`
3. **Clones** latest stable module sources
4. **Runs** `./configure $ORIGINAL_FLAGS --add-dynamic-module=...` (no binary rebuild)
5. **Runs** `make -j$(nproc) modules` — builds only `.so` files
6. **Backs up** existing `.so` files to `/usr/lib/nginx/modules/backup-*/`
7. **Installs** new `.so` → `/usr/lib/nginx/modules/`
8. **Restores** `load_module` directives in `/etc/nginx/nginx.conf`
9. Runs `nginx -t` → `systemctl start nginx`

## Requirements

- Ubuntu Noble 24.04 (or any Debian-based with `apt`)
- Nginx installed from `nginx.org` packages
- Internet access for wget/git
- ~200 MB free disk space for build

## After upgrade

Every time Nginx is upgraded from `nginx.org`, re-run the script:

```bash
sudo bash compile-nginx-modules.sh
```

The script always auto-detects the current nginx version.

## Rollback

Old modules are backed up automatically:

```bash
# List backups
ls /usr/lib/nginx/modules/backup-*/

# Rollback
sudo cp /usr/lib/nginx/modules/backup-<timestamp>/*.so /usr/lib/nginx/modules/
sudo systemctl restart nginx
```

#!/bin/sh
set -eu

upload_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
config_path=${PROXY_CONFIG:-"$upload_dir/config.env"}
case "$config_path" in
    /*) ;;
    *) config_path=$PWD/$config_path ;;
esac
if [ ! -r "$config_path" ]; then
    printf 'Config file not found: %s (copy config.env.example or set PROXY_CONFIG)\n' "$config_path" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$config_path"
: "${PROXY_APP:?Set PROXY_APP in $config_path}"
: "${PROXY_PAGE_DIR:?Set PROXY_PAGE_DIR in $config_path}"
: "${PROXY_NGINX_CONFIG:?Set PROXY_NGINX_CONFIG in $config_path}"
: "${PROXY_BACKUP_DIR:?Set PROXY_BACKUP_DIR in $config_path}"
: "${PROXY_FILE_OWNER:?Set PROXY_FILE_OWNER in $config_path}"
: "${PROXY_FILE_GROUP:?Set PROXY_FILE_GROUP in $config_path}"

page_dir=$PROXY_PAGE_DIR
case "$page_dir" in
    *'$'*)
        printf 'PROXY_PAGE_DIR cannot contain a dollar sign.\n' >&2
        exit 1
        ;;
esac
config_file=$PROXY_NGINX_CONFIG
backup_dir=$PROXY_BACKUP_DIR/$(date -u +%Y%m%dT%H%M%SZ)
rendered_config=$(mktemp)
trap 'rm -f "$rendered_config"' EXIT HUP INT TERM
nginx_root=$(printf '%s\n' "$page_dir" | sed 's/[\\"]/\\&/g')
nginx_root=$(printf '%s\n' "$nginx_root" | sed 's/[\\&|]/\\&/g')
sed "s|@PROXY_PAGE_DIR@|$nginx_root|g" "$upload_dir/nginx.conf" > "$rendered_config"

install -d -m 755 "$backup_dir"
cp -a "$page_dir" "$backup_dir/public"
cp -a "$config_file" "$backup_dir/public-access.conf"

cp -R "$upload_dir/public/." "$page_dir/"
chmod -R u=rwX,go=rX "$page_dir"
install -o "$PROXY_FILE_OWNER" -g "$PROXY_FILE_GROUP" -m 644 "$rendered_config" "$config_file"

if ! dokku proxy:build-config "$PROXY_APP"; then
    cp -a "$backup_dir/public-access.conf" "$config_file"
    cp -a "$backup_dir/public/." "$page_dir/"
    dokku proxy:build-config "$PROXY_APP"
    printf 'Installation failed. Restored the previous page and routing. Backup: %s\n' "$backup_dir" >&2
    exit 1
fi

printf 'Homepage installed. Backup: %s\n' "$backup_dir"

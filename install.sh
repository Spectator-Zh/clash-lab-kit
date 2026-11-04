#!/usr/bin/env bash
# shellcheck disable=SC1091
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR" || exit 1
. "${SCRIPT_DIR}/script/common.sh"
. "${SCRIPT_DIR}/script/clashctl.sh"

_valid_env || exit 1

# Resolve the configuration source before creating, downloading, or installing
# anything. With no URL, config.yaml in the repository root is mandatory.
url=${1:-${MIHOMO_SUBSCRIPTION_URL:-}}
ROOT_CONFIG="${SCRIPT_DIR}/config.yaml"
if [ -n "$url" ]; then
    case "$url" in
    http://* | https://*) CONFIG_SOURCE=url ;;
    *) _error_quit "订阅地址无效：必须以 http:// 或 https:// 开头" ;;
    esac
elif [ -s "$ROOT_CONFIG" ] && [ "$(wc -l < "$ROOT_CONFIG")" -gt 1 ]; then
    CONFIG_SOURCE=file
else
    _error_quit "缺少有效配置：请先在仓库根目录放置 config.yaml，或执行 bash install.sh 'https://订阅链接'"
fi

INSTALL_POINTER="$HOME/.config/clash-lab-kit/install-path"
if [ -e "$INSTALL_POINTER" ]; then
    _error_quit "已记录安装目录，请先运行 bash uninstall.sh 卸载现有安装"
fi
if [ -e "$HOME/tools/mihomo" ]; then
    _error_quit "检测到默认目录已有安装，请先执行 bash uninstall.sh 卸载"
fi
FINAL_MIHOMO_BASE_DIR="$HOME/tools/mihomo"
if _has_tty; then
    printf '安装目录（默认 %s，直接回车使用默认目录）: ' "$FINAL_MIHOMO_BASE_DIR"
    read -r install_choice || _error_quit "未能读取安装目录"
    [ -z "$install_choice" ] || FINAL_MIHOMO_BASE_DIR=$install_choice
fi
case "$FINAL_MIHOMO_BASE_DIR" in
    '~') FINAL_MIHOMO_BASE_DIR=$HOME ;;
    '~/'*) FINAL_MIHOMO_BASE_DIR="$HOME/${FINAL_MIHOMO_BASE_DIR:2}" ;;
esac
case "$FINAL_MIHOMO_BASE_DIR" in
    /*) ;;
    *) _error_quit "安装目录必须是绝对路径或以 ~/ 开头" ;;
esac
# Keep shell integration and systemd unit paths unambiguous and safe.
case "$FINAL_MIHOMO_BASE_DIR" in
    *[!a-zA-Z0-9_./-]*) _error_quit "安装目录仅支持英文字母、数字、下划线、连字符和斜杠" ;;
esac
FINAL_MIHOMO_BASE_DIR=$(realpath -m -- "$FINAL_MIHOMO_BASE_DIR") || _error_quit "无法解析安装目录"
case "$FINAL_MIHOMO_BASE_DIR" in
    /|"$HOME") _error_quit "不能将根目录或用户主目录作为安装目录" ;;
esac
if [ -e "$FINAL_MIHOMO_BASE_DIR" ]; then
    _error_quit "请先执行卸载脚本,以清除安装路径：$FINAL_MIHOMO_BASE_DIR"
fi

INSTALL_PARENT=$(dirname "$FINAL_MIHOMO_BASE_DIR")
INSTALL_STAGE="${INSTALL_PARENT}/.mihomo-install-$$-${RANDOM:-0}"
INSTALL_PUBLISHED=0
INSTALL_SUCCEEDED=0
INSTALL_RC_TOUCHED=0
INSTALL_TRANSACTION_ACTIVE=1

_use_install_base() {
    MIHOMO_BASE_DIR=$1
    MIHOMO_SCRIPT_DIR="${MIHOMO_BASE_DIR}/$(basename "$SCRIPT_BASE_DIR")"
    MIHOMO_CONFIG_URL="${MIHOMO_BASE_DIR}/url"
    MIHOMO_CONFIG_RAW="${MIHOMO_BASE_DIR}/$(basename "$RESOURCES_CONFIG")"
    MIHOMO_CONFIG_RAW_BAK="${MIHOMO_CONFIG_RAW}.bak"
    MIHOMO_CONFIG_MIXIN="${MIHOMO_BASE_DIR}/$(basename "$RESOURCES_CONFIG_MIXIN")"
    MIHOMO_CONFIG_RUNTIME="${MIHOMO_BASE_DIR}/runtime.yaml"
    MIHOMO_UPDATE_LOG="${MIHOMO_BASE_DIR}/mihomoctl.log"
    MIHOMO_PORT_STATE="${MIHOMO_BASE_DIR}/config/ports.conf"
    MIHOMO_PORT_PREF="${MIHOMO_BASE_DIR}/config/port.pref"

    CLASH_BASE_DIR=$MIHOMO_BASE_DIR
    CLASH_SCRIPT_DIR=$MIHOMO_SCRIPT_DIR
    CLASH_CONFIG_URL=$MIHOMO_CONFIG_URL
    CLASH_CONFIG_RAW=$MIHOMO_CONFIG_RAW
    CLASH_CONFIG_RAW_BAK=$MIHOMO_CONFIG_RAW_BAK
    CLASH_CONFIG_MIXIN=$MIHOMO_CONFIG_MIXIN
    CLASH_CONFIG_RUNTIME=$MIHOMO_CONFIG_RUNTIME
    CLASH_UPDATE_LOG=$MIHOMO_UPDATE_LOG
    _set_bin
}

_cleanup_install() {
    local status=${1:-1}
    trap - EXIT INT TERM HUP

    if [ "$INSTALL_SUCCEEDED" -ne 1 ]; then
        rm -f -- "$INSTALL_POINTER"
        if [ "$INSTALL_RC_TOUCHED" -eq 1 ]; then
            _use_install_base "$FINAL_MIHOMO_BASE_DIR"
            _set_rc unset >/dev/null 2>&1 || true
        fi
        if [ "$INSTALL_PUBLISHED" -eq 1 ]; then
            _use_install_base "$FINAL_MIHOMO_BASE_DIR"
            stop_mihomo >/dev/null 2>&1 || true
            rm -rf -- "$FINAL_MIHOMO_BASE_DIR"
        else
            rm -rf -- "$INSTALL_STAGE"
        fi
        _failcat "安装未完成，已清理本次安装产生的文件" || true
    fi
    exit "$status"
}
trap '_cleanup_install $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$INSTALL_PARENT" || exit 1
mkdir -m 700 "$INSTALL_STAGE" || exit 1
_use_install_base "$INSTALL_STAGE"

_get_kernel || _error_quit "无法准备 Mihomo 内核"
_validate_install_resources || _error_quit "当前安装包的 ${MIHOMO_RESOURCE_ARCH} 资源不完整或已损坏"
mkdir -p "$MIHOMO_BASE_DIR"/{bin,config,logs} || exit 1

if ! gzip -dc "$ZIP_KERNEL" > "${MIHOMO_BASE_DIR}/bin/$BIN_KERNEL_NAME"; then
    _error_quit "解压内核文件失败: $ZIP_KERNEL"
fi
chmod +x "${MIHOMO_BASE_DIR}/bin/$BIN_KERNEL_NAME"

if ! tar -xf "$ZIP_SUBCONVERTER" -C "${MIHOMO_BASE_DIR}/bin"; then
    _error_quit "解压 subconverter 失败: $ZIP_SUBCONVERTER"
fi
if ! tar -xf "$ZIP_YQ" -C "${MIHOMO_BASE_DIR}/bin"; then
    _error_quit "解压 yq 失败: $ZIP_YQ"
fi
for yq_file in "${MIHOMO_BASE_DIR}/bin"/yq_*; do
    if [ -f "$yq_file" ]; then
        mv "$yq_file" "${MIHOMO_BASE_DIR}/bin/yq"
        break
    fi
done
chmod +x "${MIHOMO_BASE_DIR}/bin/yq"
_set_bin

chmod +x "$BIN_SUBCONVERTER" 2>/dev/null || true
_validate_host_binary "$BIN_KERNEL" || _error_quit "mihomo 内核与当前系统架构不匹配"
_validate_host_binary "$BIN_YQ" || _error_quit "yq 与当前系统架构不匹配"
_validate_host_binary "$BIN_SUBCONVERTER" || _error_quit "subconverter 与当前系统架构不匹配"
_okcat '✅' "二进制架构校验通过：${MIHOMO_HOST_ARCH} (${MIHOMO_RESOURCE_ARCH})"

cp -rf "$SCRIPT_BASE_DIR" "$MIHOMO_BASE_DIR/" || exit 1
cp "$RESOURCES_CONFIG_MIXIN" "$MIHOMO_CONFIG_MIXIN" || exit 1
mkdir -p "$MIHOMO_BASE_DIR/licenses" || exit 1
cp "$SCRIPT_DIR/LICENSE" "$MIHOMO_BASE_DIR/LICENSE" || exit 1
cp "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" "$MIHOMO_BASE_DIR/THIRD_PARTY_NOTICES.md" || exit 1
cp "$SCRIPT_DIR"/third_party/licenses/* "$MIHOMO_BASE_DIR/licenses/" || exit 1
if [ -f "$RESOURCES_BASE_DIR/app-manifest.yaml" ]; then
    mkdir -p "$MIHOMO_BASE_DIR/config/templates" || exit 1
    cp "$RESOURCES_BASE_DIR/app-manifest.yaml" "$MIHOMO_BASE_DIR/config/app-manifest.yaml" || exit 1
    cp "$RESOURCES_CONFIG_MIXIN" "$MIHOMO_BASE_DIR/config/templates/mixin.yaml" || exit 1
fi
cp "$RESOURCES_BASE_DIR"/*.mmdb "$MIHOMO_BASE_DIR/" 2>/dev/null || true
cp "$RESOURCES_BASE_DIR"/*.dat "$MIHOMO_BASE_DIR/" 2>/dev/null || true
if [ -f "$ZIP_BASE_DIR/geodata-offline.tar.gz" ]; then
    tar -xzf "$ZIP_BASE_DIR/geodata-offline.tar.gz" --no-same-owner -C "$MIHOMO_BASE_DIR" ||
        _error_quit "解压离线地理数据失败"
fi

if ! unzip -q -o "$ZIP_UI" -d "$MIHOMO_BASE_DIR"; then
    _error_quit "解压 UI 文件失败: $ZIP_UI"
fi
mv "${MIHOMO_BASE_DIR}/dist" "${MIHOMO_BASE_DIR}/ui" || exit 1

if [ "$CONFIG_SOURCE" = file ]; then
    cp "$ROOT_CONFIG" "$MIHOMO_CONFIG_RAW" || exit 1
else
    _okcat '⏳' '正在下载并验证订阅配置...'
    if ! _download_config "$MIHOMO_CONFIG_RAW" "$url"; then
        _error_quit "订阅下载或转换失败：$url"
    fi
    printf '%s\n' "$url" > "$MIHOMO_CONFIG_URL"
fi

if ! _prepare_config_data "$MIHOMO_CONFIG_RAW"; then
    _error_quit "配置依赖数据准备失败：$MIHOMO_CONFIG_RAW"
fi

# Keep the bundled data until the online replacements have passed validation.
GEODATA_BACKUP="$MIHOMO_BASE_DIR/config/geodata-offline"
mkdir -p "$GEODATA_BACKUP" || exit 1
_validate_downloaded_geodata() {
    local name=$1 candidate=$2 check_dir rule mode=false result
    check_dir=$(mktemp -d "$MIHOMO_BASE_DIR/.geodata-check.XXXXXX") || return 1
    case "$name" in
        GeoSite.dat) rule='GEOSITE,CN,DIRECT' ;;
        GeoIP.dat) rule='GEOIP,CN,DIRECT'; mode=true ;;
        ASN.mmdb) rule='IP-ASN,13335,DIRECT' ;;
        *) rm -rf -- "$check_dir"; return 1 ;;
    esac
    cp "$candidate" "$check_dir/$name" || { rm -rf -- "$check_dir"; return 1; }
    printf 'geodata-mode: %s\ngeox-url:\n  geoip: http://127.0.0.1:1/\n  geosite: http://127.0.0.1:1/\n  asn: http://127.0.0.1:1/\nrules:\n  - %s\n  - MATCH,DIRECT\n' "$mode" "$rule" > "$check_dir/config.yaml"
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 "$BIN_KERNEL" -d "$check_dir" -f "$check_dir/config.yaml" -t >/dev/null 2>&1 && result=0 || result=1
    else
        "$BIN_KERNEL" -d "$check_dir" -f "$check_dir/config.yaml" -t >/dev/null 2>&1 && result=0 || result=1
    fi
    rm -rf -- "$check_dir"
    return "$result"
}
for geodata_name in GeoSite.dat GeoIP.dat ASN.mmdb; do
    [ ! -f "$MIHOMO_BASE_DIR/$geodata_name" ] || cp "$MIHOMO_BASE_DIR/$geodata_name" "$GEODATA_BACKUP/$geodata_name" || exit 1
    case "$geodata_name" in
        GeoSite.dat) geodata_asset=geosite.dat ;;
        GeoIP.dat) geodata_asset=geoip.dat ;;
        ASN.mmdb) geodata_asset=GeoLite2-ASN.mmdb ;;
    esac
    geodata_tmp="$MIHOMO_BASE_DIR/$geodata_name.download"
    if curl --silent --fail --location --connect-timeout 3 --max-time 10 \
        --output "$geodata_tmp" "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/$geodata_asset" && [ -s "$geodata_tmp" ] &&
        _validate_downloaded_geodata "$geodata_name" "$geodata_tmp"; then
        mv "$geodata_tmp" "$MIHOMO_BASE_DIR/$geodata_name" || exit 1
        _okcat '🌐' "$geodata_name 已获取在线数据"
    else
        rm -f "$geodata_tmp"
        _okcat '📦' "$geodata_name 使用本地数据"
    fi
done
_restore_offline_geodata() {
    for geodata_name in GeoSite.dat GeoIP.dat ASN.mmdb; do
        [ ! -f "$GEODATA_BACKUP/$geodata_name" ] || cp "$GEODATA_BACKUP/$geodata_name" "$MIHOMO_BASE_DIR/$geodata_name" || return 1
    done
}
if ! _valid_config "$MIHOMO_CONFIG_RAW"; then
    _okcat '📦' '在线地理数据校验失败，尝试使用包内数据'
    _restore_offline_geodata || exit 1
    _valid_config "$MIHOMO_CONFIG_RAW" || _error_quit "配置校验失败：$MIHOMO_CONFIG_RAW；转换日志：$BIN_SUBCONVERTER_LOG"
fi

# Validate the same merged runtime configuration that will be used to start
# Mihomo, while every file is still isolated in the staging directory.
_configure_url_test_groups "$MIHOMO_CONFIG_RAW" || exit 1
if ! "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
    "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"; then
    _error_quit "生成运行时配置失败"
fi
if ! _valid_config "$MIHOMO_CONFIG_RUNTIME"; then
    _restore_offline_geodata || exit 1
    _valid_config "$MIHOMO_CONFIG_RUNTIME" || _error_quit "合并后的运行时配置校验失败：$MIHOMO_CONFIG_RUNTIME"
fi
_okcat '✅' '配置及依赖数据校验通过'

# The staging directory is on the same filesystem as the final directory, so
# rename publishes the complete installation in one atomic filesystem step.
if ! mv "$INSTALL_STAGE" "$FINAL_MIHOMO_BASE_DIR"; then
    _error_quit "无法写入安装目录：$FINAL_MIHOMO_BASE_DIR"
fi
INSTALL_PUBLISHED=1
_use_install_base "$FINAL_MIHOMO_BASE_DIR"

if ! mihomoctl on; then
    _error_quit "代理启动失败；本次安装将自动清理"
fi
if ! is_mihomo_running; then
    _error_quit "代理进程验证失败；本次安装将自动清理"
fi
_get_proxy_port
_get_ui_port
if ! _is_bind "$MIXED_PORT" >/dev/null 2>&1 || ! _is_bind "$UI_PORT" >/dev/null 2>&1; then
    _error_quit "代理或管理端口未正常监听；本次安装将自动清理"
fi

# Shell integration is the only external state written by the installer, and
# it is deliberately delayed until the installed service is known to work.
INSTALL_RC_TOUCHED=1
if ! _set_rc; then
    _error_quit "写入 shell 配置失败；本次安装将自动清理"
fi

mkdir -p "$(dirname "$INSTALL_POINTER")" || _error_quit "无法记录安装目录"
printf '%s\n' "$FINAL_MIHOMO_BASE_DIR" > "$INSTALL_POINTER" || _error_quit "无法记录安装目录"
INSTALL_SUCCEEDED=1
INSTALL_TRANSACTION_ACTIVE=0
trap - EXIT INT TERM HUP

clashui

_okcat '🎉' 'mihomo 用户空间代理已安装完成！'
_okcat '📝' '使用说明：'
_okcat '💡' '统一使用 clash 命令：'
_okcat '  • 开启/关闭: clash on/off'
_okcat '  • 刷新当前终端代理: clash proxy reload'
_okcat '  • 节点测速: clash refresh [关键词]'
_okcat '  • 删除香港节点: clash hkkill'
_okcat '  • 清理 OpenAI 地区受限节点: clash hkkillpro'
_okcat '  • 重启服务: clash restart'
_okcat '  • 查看状态: clash status'
_okcat '  • 内核版本/更新: clash mihomo version|update'
_okcat '  • Web控制台: clash ui'
_okcat '  • 更新订阅: clash update [auto|log]'
_okcat '  • 更新程序: clash update app'
_okcat '  • 自动启动: clash autostart [on|off|status]'
_okcat '  • 设置订阅: clash subscribe [URL]'
_okcat '  • 系统代理: clash proxy [reload|off|status]'
_okcat '  • 局域网访问: clash lan [on|off|status]'
_okcat ''
_okcat '🏠' "安装目录: $MIHOMO_BASE_DIR"
_okcat '📁' "配置目录: $MIHOMO_BASE_DIR/config/"
_okcat '📋' "日志目录: $MIHOMO_BASE_DIR/logs/"

_okcat ''
_okcat '🚀' '登录自动启动：开启后，该用户每次登录并建立后台用户会话时都会自动启动 Clash。'
_okcat '  • 关闭命令: clash autostart off'
if _has_tty; then
    printf '是否开启登录自动启动? [y/N]: '
    response=
    read -r response || response=
    case "$response" in
    [yY] | [yY][eE][sS])
        clashautostart on || _failcat "自动启动设置失败，可稍后执行 clash autostart on 重试"
        ;;
    *)
        _okcat '未开启登录自动启动，可稍后执行 clash autostart on'
        ;;
    esac
else
    _okcat '非交互安装未开启登录自动启动，可稍后执行 clash autostart on'
fi

_okcat ''
case "$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)" in
http://* | https://*)
    _okcat '🔄' '订阅自动更新：开启后，每2天自动更新一次当前订阅配置。'
    _okcat '  • 关闭命令: clash update auto off'
    if _has_tty; then
        printf '是否开启订阅自动更新? [y/N]: '
        response=
        read -r response || response=
        case "$response" in
        [yY] | [yY][eE][sS])
            clashupdate auto on || _failcat "订阅自动更新设置失败，可稍后执行 clash update auto on 重试"
            ;;
        *)
            _okcat '未开启订阅自动更新，可稍后执行 clash update auto on'
            ;;
        esac
    else
        _okcat '非交互安装未开启订阅自动更新，可稍后执行 clash update auto on'
    fi
    ;;
*)
    _okcat '🔄' '当前使用本地配置，未设置订阅自动更新。设置订阅后可执行 clash update auto on。'
    _okcat '  • 关闭命令: clash update auto off'
    ;;
esac

_quit

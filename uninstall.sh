#!/usr/bin/env bash
# shellcheck disable=SC1091
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR" || exit 1
. "${SCRIPT_DIR}/script/common.sh"
. "${SCRIPT_DIR}/script/clashctl.sh"

_valid_env || exit 1

# 停用并删除用户级 systemd 服务
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "$MIHOMO_SYSTEMD_SERVICE_NAME" 2>/dev/null || true
    rm -f "$MIHOMO_SYSTEMD_SERVICE_PATH"
    systemctl --user daemon-reload 2>/dev/null || true
fi

# 停止 mihomo 进程
mihomoctl off >&/dev/null

# 移除用户级定时任务
crontab -l 2>/dev/null | grep -v 'mihomoctl_auto_update' | crontab - 2>/dev/null

# 删除用户目录安装
rm -rf "$MIHOMO_BASE_DIR"

# 清理被断电或 SIGKILL 遗留的同目录安装暂存区。正常失败会由安装器自行清理。
MIHOMO_INSTALL_PARENT=$(dirname "$MIHOMO_BASE_DIR")
if [ -d "$MIHOMO_INSTALL_PARENT" ]; then
    find "$MIHOMO_INSTALL_PARENT" -maxdepth 1 -type d -name '.mihomo-install-*' \
        -exec rm -rf -- {} + 2>/dev/null || true
fi

# 清理临时资源目录（如果存在）
rm -rf "$RESOURCES_BIN_DIR"

# 清理 shell 配置
_set_rc unset

_okcat '✨' '已卸载 mihomo 用户空间代理，相关配置已清除'
_okcat '📝' '注意：请重新加载 shell 配置或重新登录以清除环境变量'
_quit

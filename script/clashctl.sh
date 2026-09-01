# shellcheck disable=SC2148
# shellcheck disable=SC2155

_configure_url_test_groups() {
    local config_file="$1"

    [ -f "$config_file" ] || return 0
    _edit_yaml_atomic "$config_file" '
        (.proxy-groups[] | select(.type == "url-test")) |= (
            .url = "https://chatgpt.com/cdn-cgi/trace" |
            .interval = 300 |
            .lazy = false |
            .tolerance = 0
        )
    ' 2>/dev/null || {
        _failcat "无法更新自动选择健康检查配置"
        return 1
    }
}

_build_runtime_config() {
    local raw_file=$1
    local mixin_file=$2
    local runtime_file=$3

    _configure_url_test_groups "$raw_file" || return 1
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$mixin_file" "$raw_file" "$mixin_file" > "$runtime_file" || return 1
    _valid_config "$runtime_file"
}

_set_system_proxy() {
    # Ensure config files exist before reading
    [ ! -f "$MIHOMO_CONFIG_RUNTIME" ] && {
        _failcat "运行时配置文件不存在: $MIHOMO_CONFIG_RUNTIME"
        return 1
    }
    
    local auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    [ -n "$auth" ] && auth=$auth@

    local http_proxy_addr="http://${auth}127.0.0.1:${MIXED_PORT}"
    local socks_proxy_addr="socks5h://${auth}127.0.0.1:${MIXED_PORT}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export https_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy

    # Ensure mixin config directory exists and update using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    _edit_yaml_atomic "$MIHOMO_CONFIG_MIXIN" '.system-proxy.enable = true' 2>/dev/null || {
        _failcat "无法更新系统代理配置"
        return 1
    }
}

_unset_system_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY

    # Ensure mixin config exists and update using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    _edit_yaml_atomic "$MIHOMO_CONFIG_MIXIN" '.system-proxy.enable = false' 2>/dev/null || {
        _failcat "无法更新系统代理配置"
    }
}

_user_systemd_available() {
    command -v systemctl >/dev/null 2>&1 &&
        systemctl --user show-environment >/dev/null 2>&1
}

_user_service_manages_mihomo() {
    [ "${MIHOMO_SYSTEMD_RUN:-0}" != "1" ] || return 1
    _user_systemd_available || return 1
    systemctl --user is-active --quiet "$MIHOMO_SYSTEMD_SERVICE_NAME" 2>/dev/null ||
        systemctl --user is-enabled --quiet "$MIHOMO_SYSTEMD_SERVICE_NAME" 2>/dev/null
}

_write_autostart_service() {
    mkdir -p "$MIHOMO_SYSTEMD_USER_DIR" || return 1
    cat > "$MIHOMO_SYSTEMD_SERVICE_PATH" <<'EOF'
[Unit]
Description=Mihomo user proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'source "%h/tools/mihomo/script/common.sh" && source "%h/tools/mihomo/script/clashctl.sh" && MIHOMO_SYSTEMD_RUN=1 clash on'
ExecStop=/bin/bash -c 'source "%h/tools/mihomo/script/common.sh" && source "%h/tools/mihomo/script/clashctl.sh" && MIHOMO_SYSTEMD_RUN=1 clash off'
TimeoutStartSec=60
TimeoutStopSec=30

[Install]
WantedBy=default.target
EOF
}

function clashautostart() {
    local action=${1:-status}
    local was_running=false

    _user_systemd_available || {
        _failcat "当前用户的 systemd 会话不可用"
        return 1
    }

    case "$action" in
    on | enable)
        is_mihomo_running && was_running=true
        _write_autostart_service || {
            _failcat "无法写入用户服务: $MIHOMO_SYSTEMD_SERVICE_PATH"
            return 1
        }
        systemctl --user daemon-reload || return 1
        systemctl --user enable "$MIHOMO_SYSTEMD_SERVICE_NAME" || return 1

        if systemctl --user is-active --quiet "$MIHOMO_SYSTEMD_SERVICE_NAME"; then
            systemctl --user restart "$MIHOMO_SYSTEMD_SERVICE_NAME" || return 1
        else
            [ "$was_running" = true ] && MIHOMO_SYSTEMD_RUN=1 clashoff >/dev/null
            systemctl --user start "$MIHOMO_SYSTEMD_SERVICE_NAME" || return 1
        fi
        _okcat "已开启登录后自动启动"
        ;;
    off | disable)
        is_mihomo_running && was_running=true
        systemctl --user disable --now "$MIHOMO_SYSTEMD_SERVICE_NAME" 2>/dev/null || true
        if [ "$was_running" = true ] && ! is_mihomo_running; then
            MIHOMO_SYSTEMD_RUN=1 clashon >/dev/null || return 1
        fi
        _okcat "已关闭登录后自动启动；当前代理保持运行"
        ;;
    status)
        local enabled=关闭 active=未运行 linger
        systemctl --user is-enabled --quiet "$MIHOMO_SYSTEMD_SERVICE_NAME" 2>/dev/null && enabled=开启
        systemctl --user is-active --quiet "$MIHOMO_SYSTEMD_SERVICE_NAME" 2>/dev/null && active=运行中
        linger=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)
        _okcat "登录后自动启动: $enabled"
        _okcat "用户服务状态: $active"
        [ "$linger" = "yes" ] &&
            _okcat "无人登录时启动: 开启 (linger=yes)" ||
            _okcat "无人登录时启动: 关闭 (linger=${linger:-unknown})"
        ;;
    *)
        _failcat "用法: clash autostart [on|off|status]"
        return 1
        ;;
    esac
}

function clashon() {
    if _user_service_manages_mihomo; then
        if systemctl --user is-active --quiet "$MIHOMO_SYSTEMD_SERVICE_NAME" && is_mihomo_running; then
            _okcat "mihomo 用户服务已在运行"
            return 0
        fi
        systemctl --user restart "$MIHOMO_SYSTEMD_SERVICE_NAME" || return 1
        _okcat "mihomo 用户服务已启动"
        return 0
    fi

    # Ensure config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_RUNTIME")"

    local staged_runtime
    staged_runtime=$(mktemp "${MIHOMO_BASE_DIR}/.runtime.start.XXXXXX") || return 1
    if ! _build_runtime_config "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" "$staged_runtime"; then
        rm -f "$staged_runtime"
        _failcat "生成或校验运行时配置失败"
        return 1
    fi

    # 检查端口冲突并显示分配结果；最终结果校验后再原子发布。
    _resolve_port_conflicts "$staged_runtime" true || {
        rm -f "$staged_runtime"
        return 1
    }
    _valid_config "$staged_runtime" || {
        rm -f "$staged_runtime"
        _failcat "端口调整后的运行时配置校验失败"
        return 1
    }
    [ -f "$MIHOMO_CONFIG_RUNTIME" ] && chmod --reference="$MIHOMO_CONFIG_RUNTIME" "$staged_runtime" 2>/dev/null || true
    mv -f "$staged_runtime" "$MIHOMO_CONFIG_RUNTIME" || {
        rm -f "$staged_runtime"
        return 1
    }
    
    # Start mihomo process
    if start_mihomo; then
        # Wait for mihomo to fully start
        sleep 2
        
        # 验证实际端口并设置端口变量
        _verify_actual_ports
        
        # 保存端口状态并设置系统代理
        _save_port_state "$MIXED_PORT" "$UI_PORT" "$DNS_PORT"
        _set_system_proxy
        _okcat '已开启代理环境'
    else
        _failcat '代理启动失败'
        return 1
    fi
}

# 验证实际监听端口与配置是否一致
_verify_actual_ports() {
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    [ ! -f "$log_file" ] && return 0
    
    # Extract actual listening ports from log
    # Try both old format (Mixed) and new format (HTTP proxy)
    local actual_proxy_port=$(grep "Mixed(http+socks) proxy listening at:" "$log_file" | tail -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
    [ -z "$actual_proxy_port" ] && actual_proxy_port=$(grep "HTTP proxy listening at:" "$log_file" | tail -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
    
    local actual_ui_port=$(grep "RESTful API listening at:" "$log_file" | tail -1 | sed -n 's/.*:\([0-9]\+\)[^0-9]*$/\1/p')
    local actual_dns_port=$(grep "DNS server(UDP) listening at:" "$log_file" | tail -1 | sed -n 's/.*\[::\]:\([0-9]*\).*/\1/p')
    
    # 从配置文件获取期望端口进行比较
    local config_proxy_port=$("$BIN_YQ" '.mixed-port // 7890' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_ui_addr=$("$BIN_YQ" '.external-controller // "127.0.0.1:9090"' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_ui_port=${config_ui_addr##*:}
    local config_dns_addr=$("$BIN_YQ" '.dns.listen // "0.0.0.0:15353"' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_dns_port=${config_dns_addr##*:}
    
    local port_changed=false
    
    # 设置实际监听端口到变量
    if [ -n "$actual_proxy_port" ]; then
        MIXED_PORT=$actual_proxy_port
        [ "$actual_proxy_port" != "$config_proxy_port" ] && {
            _failcat "🔄" "mihomo自动调整代理端口: $config_proxy_port → $actual_proxy_port"
            port_changed=true
        }
    else
        MIXED_PORT=$config_proxy_port
    fi
    
    if [ -n "$actual_ui_port" ]; then
        UI_PORT=$actual_ui_port
        [ "$actual_ui_port" != "$config_ui_port" ] && {
            _failcat "🔄" "mihomo自动调整UI端口: $config_ui_port → $actual_ui_port"
            port_changed=true
        }
    else
        UI_PORT=$config_ui_port
    fi
    
    if [ -n "$actual_dns_port" ]; then
        DNS_PORT=$actual_dns_port
        [ "$actual_dns_port" != "$config_dns_port" ] && {
            _failcat "🔄" "mihomo自动调整DNS端口: $config_dns_port → $actual_dns_port"
            port_changed=true
        }
    else
        DNS_PORT=$config_dns_port
    fi
    
    # 只有当端口有变化时才显示最终端口分配并重新设置系统代理
    if [ "$port_changed" = true ]; then
        _okcat "最终端口分配 - 代理:$MIXED_PORT UI:$UI_PORT DNS:$DNS_PORT"
        # 保存实际监听端口到状态文件
        _save_port_state "$MIXED_PORT" "$UI_PORT" "$DNS_PORT"
        # 端口变化时重新设置系统代理环境变量
        _set_system_proxy
    fi
}

watch_proxy() {
    # 新开交互式shell，且无代理变量时
    [ -z "$http_proxy" ] && [[ $- == *i* ]] && {
        # 检查用户是否启用系统代理
        local system_proxy_status=$("$BIN_YQ" '.system-proxy.enable // true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)

        # 仅当用户启用系统代理且 mihomo 进程运行时，自动写入环境变量
        if [ "$system_proxy_status" = "true" ] && is_mihomo_running; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _set_system_proxy
        fi
    }
}

function clashoff() {
    if _user_service_manages_mihomo && systemctl --user is-active --quiet "$MIHOMO_SYSTEMD_SERVICE_NAME"; then
        systemctl --user stop "$MIHOMO_SYSTEMD_SERVICE_NAME" || return 1
        _okcat '已关闭代理环境'
        return 0
    fi

    # Stop mihomo process
    stop_mihomo
    _unset_system_proxy
    _okcat '已关闭代理环境'
}

function clashrestart() {
    if _user_service_manages_mihomo; then
        _okcat "正在重启代理服务..."
        systemctl --user restart "$MIHOMO_SYSTEMD_SERVICE_NAME" || return 1
        _okcat "代理服务重启成功"
        return 0
    fi

    _okcat "正在重启代理服务..."
    { clashoff && clashon; } >&/dev/null && _okcat "代理服务重启成功"
}

function clashrefresh() {
    if ! is_mihomo_running; then
        _failcat "无法测速：mihomo 进程未运行"
        return 1
    fi

    command -v python3 >/dev/null 2>&1 || {
        _failcat "缺少 python3，无法解析测速结果"
        return 1
    }

    local keyword="$*"
    local ui_host="127.0.0.1"
    local ui_port controller_addr secret group_name test_url encoded_group
    local result_file result_code result_summary fastest_payload selector_payload current_node
    local -a auth_args=()

    _get_ui_port
    ui_port=$UI_PORT
    controller_addr=$("$BIN_YQ" '.external-controller // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    secret=$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    [ -z "$ui_port" ] && [ -n "$controller_addr" ] && ui_port=${controller_addr##*:}
    [ -z "$ui_port" ] && ui_port=9090
    [ -n "$secret" ] && auth_args=(-H "Authorization: Bearer ${secret}")

    group_name=$("$BIN_YQ" -r '.proxy-groups[] | select(.type == "url-test") | .name' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null | head -1)
    [ -z "$group_name" ] && {
        _failcat "未找到 url-test 类型的自动选择组"
        return 1
    }
    test_url=$("$BIN_YQ" -r ".proxy-groups[] | select(.name == \"${group_name}\") | .url" "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    [ -z "$test_url" ] || [ "$test_url" = "null" ] && test_url="https://chatgpt.com/cdn-cgi/trace"
    encoded_group=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$group_name")
    result_file=$(mktemp)

    if [ -n "$keyword" ]; then
        _okcat "正在测试名称包含“${keyword}”的节点..."
        CLASH_REFRESH_SECRET="$secret" python3 - \
            "http://${ui_host}:${ui_port}" "$group_name" "$keyword" "$test_url" "$result_file" <<'PY'
import concurrent.futures
import json
import os
import sys
import urllib.parse
import urllib.request

base, group, keyword, test_url, output = sys.argv[1:]
secret = os.environ.get("CLASH_REFRESH_SECRET", "")
headers = {"Authorization": f"Bearer {secret}"} if secret else {}

def get_json(url, timeout):
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)

proxies = get_json(f"{base}/proxies", 5)["proxies"]
members = proxies.get(group, {}).get("all", [])
needle = keyword.casefold()
candidates = [name for name in members if needle in name.casefold()]

def measure(name):
    path = urllib.parse.quote(name, safe="")
    query = urllib.parse.urlencode({"url": test_url, "timeout": 10000})
    try:
        data = get_json(f"{base}/proxies/{path}/delay?{query}", 12)
        delay = data.get("delay")
        if isinstance(delay, (int, float)) and delay > 0:
            return name, delay
    except Exception:
        pass
    return name, None

delays = {}
if candidates:
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(16, len(candidates))) as pool:
        for name, delay in pool.map(measure, candidates):
            if delay is not None:
                delays[name] = delay

with open(output, "w", encoding="utf-8") as stream:
    json.dump({"tested": len(candidates), "delays": delays}, stream, ensure_ascii=False)
PY
        result_code=$?
        [ "$result_code" = "0" ] || {
            rm -f "$result_file"
            _failcat "筛选节点测速请求失败"
            return 1
        }
    else
        _okcat "正在测试自动选择组的全部节点..."
        result_code=$(curl --noproxy "*" --silent --show-error --max-time 20 \
            "${auth_args[@]}" --output "$result_file" --write-out '%{http_code}' --get \
            "http://${ui_host}:${ui_port}/group/${encoded_group}/delay" \
            --data-urlencode "url=${test_url}" --data-urlencode 'timeout=10000') || {
            rm -f "$result_file"
            _failcat "节点测速请求失败"
            return 1
        }
        [ "$result_code" = "200" ] || {
            rm -f "$result_file"
            _failcat "节点测速失败，管理端返回 HTTP ${result_code}"
            return 1
        }
    fi

    result_summary=$(python3 - "$result_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
tested = data.get("tested", len(data)) if isinstance(data, dict) else 0
delays = data.get("delays", data) if isinstance(data, dict) else {}
available = [(delay, name) for name, delay in delays.items()
             if isinstance(delay, (int, float)) and delay > 0]
if tested == 0:
    raise SystemExit(2)
if not available:
    raise SystemExit(1)
delay, name = min(available)
print(f"{tested}\t{len(available)}\t{name}\t{delay}")
PY
    )
    result_code=$?
    if [ "$result_code" = "2" ]; then
        rm -f "$result_file"
        _failcat "没有找到名称包含“${keyword}”的节点"
        return 1
    elif [ "$result_code" != "0" ]; then
        rm -f "$result_file"
        [ -n "$keyword" ] && _failcat "匹配“${keyword}”的节点全部不可用" || _failcat "没有测到可用节点"
        return 1
    fi
    rm -f "$result_file"

    local tested available fastest delay
    IFS=$'\t' read -r tested available fastest delay <<< "$result_summary"

    fastest_payload=$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1]}, ensure_ascii=False))' "$fastest")
    curl --noproxy "*" --silent --show-error --fail \
        "${auth_args[@]}" -X PUT -H 'Content-Type: application/json' \
        -d "$fastest_payload" "http://${ui_host}:${ui_port}/proxies/${encoded_group}" >/dev/null || {
        _failcat "测速完成，但无法应用最快节点"
        return 1
    }

    selector_payload=$(python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1]}, ensure_ascii=False))' "$group_name")
    curl --noproxy "*" --silent --show-error --fail \
        "${auth_args[@]}" -X PUT -H 'Content-Type: application/json' \
        -d "$selector_payload" "http://${ui_host}:${ui_port}/proxies/Proxy" >/dev/null || {
        _failcat "测速完成，但无法将 Proxy 切换到 ${group_name}"
        return 1
    }

    sleep 1
    current_node=$(curl --noproxy "*" --silent --show-error --fail "${auth_args[@]}" \
        "http://${ui_host}:${ui_port}/proxies" | python3 -c '
import json, sys
d = json.load(sys.stdin)["proxies"]
group = sys.argv[1]
print(d.get(group, {}).get("now", "未知"))
' "$group_name") || current_node="未知"

    _okcat "测速完成：${available}/${tested} 个节点可用"
    _okcat "实测最快：${fastest} (${delay} ms)"
    _okcat "当前选择：${current_node}"
}

_remove_named_nodes() {
    local names="$1" backup_tag="$2" description="$3" count="$4"
    local staged backup node_name was_running=false

    staged=$(mktemp "${MIHOMO_BASE_DIR}/.config.${backup_tag}.XXXXXX") || return 1
    cp "$MIHOMO_CONFIG_RAW" "$staged" || {
        rm -f "$staged"
        return 1
    }

    while IFS= read -r node_name; do
        [ -n "$node_name" ] || continue
        TARGET_NODE_NAME=$node_name "$BIN_YQ" -i '
            del(.proxies[] | select(.name == strenv(TARGET_NODE_NAME))) |
            (.proxy-groups[]?.proxies) |= ((. // []) | map(select(. != strenv(TARGET_NODE_NAME))))
        ' "$staged" || {
            rm -f "$staged"
            _failcat "删除节点失败，原配置未改动：$node_name"
            return 1
        }
    done < "$names"

    if ! _valid_config "$staged"; then
        rm -f "$staged"
        _failcat "删除后配置校验失败，原配置未改动"
        return 1
    fi

    mkdir -p "${MIHOMO_BASE_DIR}/config" || {
        rm -f "$staged"
        return 1
    }
    backup="${MIHOMO_BASE_DIR}/config/config.before-${backup_tag}.$(date +%Y%m%d%H%M%S).yaml"
    cp -p "$MIHOMO_CONFIG_RAW" "$backup" || {
        rm -f "$staged"
        _failcat "无法备份配置，操作已取消"
        return 1
    }

    is_mihomo_running && was_running=true
    if [ "$was_running" = true ]; then
        if ! _apply_config_transaction "$staged" "$MIHOMO_CONFIG_MIXIN"; then
            rm -f "$staged"
            _failcat "应用配置失败，原配置和运行状态未改变"
            return 1
        fi
        rm -f "$staged"
    elif ! mv -f "$staged" "$MIHOMO_CONFIG_RAW"; then
        rm -f "$staged"
        _failcat "无法替换配置，原配置仍保存在：$backup"
        return 1
    fi

    _okcat "已删除 ${count} 个节点（${description}）"
    _okcat "原配置备份：$backup"
    [ "$was_running" = false ] && _okcat "代理当前未运行，新配置将在下次 clash on 时生效"
}

function clashhkkill() {
    [ -s "$MIHOMO_CONFIG_RAW" ] || {
        _failcat "配置文件不存在：$MIHOMO_CONFIG_RAW"
        return 1
    }

    local pattern='(?i)(香港|hongkong)'
    local names count=0 result
    names=$(mktemp "${MIHOMO_BASE_DIR}/.nodes.hkkill.XXXXXX") || return 1

    HK_NODE_PATTERN=$pattern "$BIN_YQ" -r \
        '.proxies[]? | select(.name | test(strenv(HK_NODE_PATTERN))) | .name' \
        "$MIHOMO_CONFIG_RAW" > "$names" || {
            rm -f "$names"
            _failcat "无法读取香港节点"
            return 1
        }

    count=$(wc -l < "$names")
    if [ "$count" -eq 0 ]; then
        rm -f "$names"
        _okcat "未找到名称包含“香港”或“hongkong”的节点，配置未改动"
        return 0
    fi

    _remove_named_nodes "$names" hkkill "名称包含香港或 hongkong" "$count"
    result=$?
    rm -f "$names"
    return "$result"
}

function clashhkkillpro() (
    [ -s "$MIHOMO_CONFIG_RAW" ] || {
        _failcat "配置文件不存在：$MIHOMO_CONFIG_RAW"
        return 1
    }
    command -v python3 >/dev/null 2>&1 || {
        _failcat "缺少 python3，无法检测节点"
        return 1
    }
    [ -x "$BIN_KERNEL" ] || {
        _failcat "未找到可执行的 Mihomo 内核：$BIN_KERNEL"
        return 1
    }

    local test_dir test_config names_file result_file probe_log probe_pid=""
    local proxy_port controller_port total blocked errors result ready=false i
    mkdir -p "${MIHOMO_BASE_DIR}/config" || return 1
    test_dir=$(mktemp -d "${MIHOMO_BASE_DIR}/config/hkkillpro.XXXXXX") || return 1
    test_config="${test_dir}/config.yaml"
    names_file="${test_dir}/blocked-nodes.txt"
    result_file="${test_dir}/result.tsv"
    probe_log="${test_dir}/mihomo.log"

    _cleanup_hkkillpro() {
        if [ -n "$probe_pid" ] && kill -0 "$probe_pid" 2>/dev/null; then
            local args
            args=$(ps -p "$probe_pid" -o args= 2>/dev/null || true)
            case "$args" in
            *"$test_dir"*)
                kill "$probe_pid" 2>/dev/null || true
                wait "$probe_pid" 2>/dev/null || true
                ;;
            esac
        fi
        rm -rf -- "$test_dir"
    }
    trap _cleanup_hkkillpro EXIT
    trap 'exit 130' INT TERM HUP

    proxy_port=$(_get_random_port)
    controller_port=$(_get_random_port)
    while [ "$controller_port" = "$proxy_port" ]; do
        controller_port=$(_get_random_port)
    done

    cp "$MIHOMO_CONFIG_RAW" "$test_config" || return 1
    PROBE_PROXY_PORT=$proxy_port PROBE_CONTROLLER_PORT=$controller_port "$BIN_YQ" -i '
        (.proxies // [] | map(.name)) as $names |
        .mode = "rule" |
        .["mixed-port"] = env(PROBE_PROXY_PORT) |
        .["external-controller"] = "127.0.0.1:" + strenv(PROBE_CONTROLLER_PORT) |
        .secret = "" |
        .["allow-lan"] = false |
        .["external-ui"] = "" |
        .tun.enable = false |
        .dns = {"enable": false} |
        .profile["store-selected"] = false |
        .["proxy-groups"] = [{"name": "HKKILL-TEST", "type": "select", "proxies": $names}] |
        .rules = ["MATCH,HKKILL-TEST"] |
        del(.port, .["socks-port"], .["redir-port"], .["tproxy-port"])
    ' "$test_config" || {
        _failcat "无法生成隔离测试配置"
        return 1
    }

    total=$("$BIN_YQ" '.proxies | length' "$test_config" 2>/dev/null)
    [ "${total:-0}" -gt 0 ] || {
        _okcat "配置中没有可测试节点，配置未改动"
        return 0
    }
    _valid_config "$test_config" || {
        _failcat "隔离测试配置校验失败，原配置未改动"
        return 1
    }

    "$BIN_KERNEL" -d "$test_dir" -f "$test_config" >"$probe_log" 2>&1 &
    probe_pid=$!
    for i in $(seq 1 50); do
        if curl --noproxy "*" --silent --fail --max-time 1 \
            "http://127.0.0.1:${controller_port}/version" >/dev/null 2>&1; then
            ready=true
            break
        fi
        kill -0 "$probe_pid" 2>/dev/null || break
        sleep 0.1
    done
    [ "$ready" = true ] || {
        _failcat "隔离测试实例启动失败，原配置未改动"
        tail -n 5 "$probe_log" >&2
        return 1
    }

    _okcat "正在隔离测试全部 ${total} 个节点，仅识别 OpenAI 明确的地区限制..."
    python3 - "$controller_port" "$proxy_port" "$names_file" "$result_file" <<'PY'
import json
import subprocess
import sys
import time
import urllib.request

controller_port, proxy_port, names_file, result_file = sys.argv[1:]
base = f"http://127.0.0.1:{controller_port}"
proxy = f"http://127.0.0.1:{proxy_port}"

with urllib.request.urlopen(f"{base}/proxies/HKKILL-TEST", timeout=5) as response:
    nodes = json.load(response).get("all", [])

blocked = []
errors = 0
for index, name in enumerate(nodes, 1):
    payload = json.dumps({"name": name}, ensure_ascii=False).encode()
    request = urllib.request.Request(
        f"{base}/proxies/HKKILL-TEST",
        data=payload,
        method="PUT",
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(request, timeout=5).read()
        time.sleep(0.2)
        command = [
            "curl", "--noproxy", "", "--silent", "--show-error",
            "--max-time", "20", "--proxy", proxy,
            "--output", "-", "--write-out", "\n%{http_code}",
            "https://api.openai.com/v1/models",
        ]
        completed = subprocess.run(command, capture_output=True, text=True)
        if completed.returncode != 0:
            errors += 1
            print(f"[{index}/{len(nodes)}] 保留（网络错误）：{name}", file=sys.stderr)
            continue
        body, _, status = completed.stdout.rpartition("\n")
        is_blocked = status == "403" and "unsupported_country_region_territory" in body
        if is_blocked:
            blocked.append(name)
            print(f"[{index}/{len(nodes)}] 删除（地区限制）：{name}", file=sys.stderr)
        else:
            print(f"[{index}/{len(nodes)}] 保留（HTTP {status}）：{name}", file=sys.stderr)
    except Exception as error:
        errors += 1
        print(f"[{index}/{len(nodes)}] 保留（测试错误）：{name}: {error}", file=sys.stderr)

with open(names_file, "w", encoding="utf-8") as stream:
    for name in blocked:
        stream.write(name + "\n")
with open(result_file, "w", encoding="utf-8") as stream:
    stream.write(f"{len(nodes)}\t{len(blocked)}\t{errors}\n")
PY
    result=$?
    [ "$result" -eq 0 ] || {
        _failcat "节点检测失败，原配置未改动"
        return 1
    }

    IFS=$'\t' read -r total blocked errors < "$result_file"
    if [ "$blocked" -eq 0 ]; then
        _okcat "检测完成：${total} 个节点中未发现明确的地区限制，配置未改动"
        [ "$errors" -gt 0 ] && _okcat "其中 ${errors} 个节点测试异常，已全部保留"
        return 0
    fi

    _remove_named_nodes "$names_file" hkkillpro "OpenAI 地区受限" "$blocked" || return 1
    [ "$errors" -gt 0 ] && _okcat "另有 ${errors} 个节点测试异常，已全部保留"
    _okcat "订阅更新可能重新加入这些节点，届时可再次执行 clash hkkillpro"
)

function clashproxy() {
    case "$1" in
    reload)
        if is_mihomo_running; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _set_system_proxy
            _okcat "已刷新当前终端代理环境（端口：$MIXED_PORT）"
        else
            _failcat "无法刷新代理环境：mihomo 进程未运行"
            return 1
        fi
        ;;
    off)
        _unset_system_proxy
        _okcat '已关闭系统代理'
        ;;
    status)
        local system_proxy_status=$("$BIN_YQ" '.system-proxy.enable' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)
        if [ "$system_proxy_status" = "false" ]; then
            _failcat "系统代理：关闭"
            return 1
        fi
        
        if is_mihomo_running; then
            _okcat "系统代理：开启
http_proxy： $http_proxy
socks_proxy：$all_proxy"
        else
            _failcat "系统代理：配置为开启，但 mihomo 进程未运行"
            return 1
        fi
        ;;
    *)
        cat <<EOF
用法: clash proxy [reload|off|status]
    reload  刷新当前终端的代理环境和端口
    off     关闭系统代理
    status  查看系统代理状态
EOF
        ;;
    esac
}

function clashport() {
    local action=$1
    shift || true

    case "$action" in
    ""|status)
        _load_port_preferences
        _get_proxy_port
        local mode_msg
        if [ "$PORT_PREF_MODE" = "manual" ] && [ -n "$PORT_PREF_VALUE" ]; then
            mode_msg="固定(${PORT_PREF_VALUE})"
        else
            mode_msg="自动"
        fi
        _okcat "端口模式：$mode_msg"
        _okcat "当前代理端口：$MIXED_PORT"
        ;;
    auto)
        _save_port_preferences auto ""
        _okcat "已切换为自动分配代理端口"
        if is_mihomo_running; then
            _okcat "正在重新应用配置..."
            clashrestart
        fi
        ;;
    set|manual)
        local manual_port=$1
        local prefer_auto=false

        while true; do
            if [ -z "$manual_port" ]; then
                printf "请输入想要固定的代理端口 [1024-65535]: "
                read -r manual_port
            fi

            if [ -z "$manual_port" ]; then
                _failcat "未输入端口"
                continue
            fi

            if ! [[ $manual_port =~ ^[0-9]+$ ]] || [ "$manual_port" -lt 1024 ] || [ "$manual_port" -gt 65535 ]; then
                _failcat "端口号无效，请输入 1024-65535 之间的数字"
                manual_port=""
                continue
            fi

            if _is_already_in_use "$manual_port" "$BIN_KERNEL_NAME"; then
                _failcat '🎯' "端口 $manual_port 已被占用"
                printf "选择操作 [r]重新输入/[a]自动分配: "
                read -r choice
                case "$choice" in
                [aA])
                    prefer_auto=true
                    break
                    ;;
                [rR])
                    manual_port=""
                    continue
                    ;;
                *)
                    manual_port=""
                    continue
                    ;;
                esac
            fi

            break
        done

        if [ "$prefer_auto" = true ]; then
            _save_port_preferences auto ""
            _okcat "已切换为自动分配代理端口"
        else
            _save_port_preferences manual "$manual_port"
            _okcat "已固定代理端口：$manual_port"
        fi

        if is_mihomo_running; then
            _okcat "正在重新应用配置..."
            clashrestart
        fi
        ;;
    *)
        cat <<EOF
用法: clashport [status|auto|set <port>]
    status          查看当前代理端口模式与端口
    auto            切换为自动分配代理端口
    set <port>      固定代理端口，端口冲突时可选择重新输入或自动分配
EOF
        ;;
    esac
}

function clashstatus() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    
    # Show subscription URL
    local subscription_url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    if [ -n "$subscription_url" ]; then
        _okcat "订阅地址: $subscription_url"
    else
        _failcat "订阅地址: 未设置"
    fi
    
    if is_mihomo_running; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        local uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
        local kernel_version=""
        [ -x "$BIN_MIHOMO" ] && kernel_version=$("$BIN_MIHOMO" -v 2>/dev/null | head -n1)
        _okcat "mihomo 进程状态: 运行中"
        [ -n "$kernel_version" ] && _okcat "内核版本: $kernel_version"
        _okcat "进程 PID: $pid"
        _okcat "运行时间: ${uptime:-未知}"
        _okcat "配置文件: $MIHOMO_CONFIG_RUNTIME"
        _okcat "日志文件: $log_file"
        
        # Show proxy port status
        if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _okcat "代理端口: $MIXED_PORT"
            _okcat "管理端口: $UI_PORT"
            _okcat "DNS端口: $DNS_PORT"
        else
            _failcat "配置文件不存在，无法获取端口信息"
        fi
        
        # Show system proxy status
        clashproxy status
    else
        _failcat "mihomo 进程状态: 未运行"
        [ -f "$pid_file" ] && {
            _failcat "发现残留 PID 文件，已清理"
            rm -f "$pid_file"
        }
        return 1
    fi
}

function clashui() {
    _get_ui_port
    local controller_addr controller_host
    controller_addr=$("$BIN_YQ" '.external-controller // "127.0.0.1:9090"' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    controller_host=${controller_addr%:*}

    case "$controller_host" in
    127.0.0.1 | localhost | ::1 | "[::1]")
        printf "\n"
        _okcat 'Web 控制台仅监听本机，未暴露给局域网或公网。'
        _okcat "本机地址：http://127.0.0.1:${UI_PORT}/ui/"
        _okcat "远程访问：ssh -L ${UI_PORT}:127.0.0.1:${UI_PORT} ${USER}@服务器地址"
        _okcat "建立 SSH 转发后，在本地浏览器打开：http://127.0.0.1:${UI_PORT}/ui/"
        printf "\n"
        return 0
        ;;
    esac

    # 公网ip
    # ifconfig.me
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 $query_url)
    local public_address="http://${public_ip:-公网}:${UI_PORT}/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$UI_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}

_apply_config_transaction() {
    local raw_source=${1:-$MIHOMO_CONFIG_RAW}
    local mixin_source=${2:-$MIHOMO_CONFIG_MIXIN}
    local staged_raw staged_mixin staged_runtime backup_dir was_running=false restore_rc=0

    mkdir -p "$MIHOMO_BASE_DIR/config" || return 1
    staged_raw=$(mktemp "${MIHOMO_BASE_DIR}/.config.raw.XXXXXX") || return 1
    staged_mixin=$(mktemp "${MIHOMO_BASE_DIR}/.config.mixin.XXXXXX") || {
        rm -f "$staged_raw"
        return 1
    }
    staged_runtime=$(mktemp "${MIHOMO_BASE_DIR}/.config.runtime.XXXXXX") || {
        rm -f "$staged_raw" "$staged_mixin"
        return 1
    }
    backup_dir=$(mktemp -d "${MIHOMO_BASE_DIR}/config/.transaction-backup.XXXXXX") || {
        rm -f "$staged_raw" "$staged_mixin" "$staged_runtime"
        return 1
    }

    if ! cp -p "$raw_source" "$staged_raw" ||
        ! cp -p "$mixin_source" "$staged_mixin" ||
        ! _build_runtime_config "$staged_raw" "$staged_mixin" "$staged_runtime"; then
        rm -f "$staged_raw" "$staged_mixin" "$staged_runtime"
        rm -rf "$backup_dir"
        _failcat "新配置生成或校验失败，现有配置未改动"
        return 1
    fi

    cp -p "$MIHOMO_CONFIG_RAW" "$backup_dir/config.yaml" || restore_rc=1
    cp -p "$MIHOMO_CONFIG_MIXIN" "$backup_dir/mixin.yaml" || restore_rc=1
    cp -p "$MIHOMO_CONFIG_RUNTIME" "$backup_dir/runtime.yaml" || restore_rc=1
    if [ "$restore_rc" -ne 0 ]; then
        rm -f "$staged_raw" "$staged_mixin" "$staged_runtime"
        rm -rf "$backup_dir"
        _failcat "无法备份现有配置，操作已取消"
        return 1
    fi

    is_mihomo_running && was_running=true
    chmod --reference="$MIHOMO_CONFIG_RUNTIME" "$staged_runtime" 2>/dev/null || true
    if ! mv -f "$staged_raw" "$MIHOMO_CONFIG_RAW" ||
        ! mv -f "$staged_mixin" "$MIHOMO_CONFIG_MIXIN" ||
        ! mv -f "$staged_runtime" "$MIHOMO_CONFIG_RUNTIME"; then
        cp -p "$backup_dir/config.yaml" "$MIHOMO_CONFIG_RAW" 2>/dev/null || true
        cp -p "$backup_dir/mixin.yaml" "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || true
        cp -p "$backup_dir/runtime.yaml" "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null || true
        rm -f "$staged_raw" "$staged_mixin" "$staged_runtime"
        rm -rf "$backup_dir"
        _failcat "配置发布失败，已恢复原配置"
        return 1
    fi

    if clashrestart; then
        rm -rf "$backup_dir"
        return 0
    fi

    cp -p "$backup_dir/config.yaml" "$MIHOMO_CONFIG_RAW" 2>/dev/null || restore_rc=1
    cp -p "$backup_dir/mixin.yaml" "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || restore_rc=1
    cp -p "$backup_dir/runtime.yaml" "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null || restore_rc=1
    if [ "$was_running" = true ]; then
        clashrestart >/dev/null 2>&1 || restore_rc=1
    else
        clashoff >/dev/null 2>&1 || true
    fi
    rm -rf "$backup_dir"
    if [ "$restore_rc" -eq 0 ]; then
        _failcat "新配置重启失败，已恢复原配置和运行状态"
    else
        _failcat "新配置重启失败，自动恢复未完全成功，请检查服务状态"
    fi
    return 1
}

_update_mixin_transaction() {
    local expression=$1
    local staged_mixin

    staged_mixin=$(mktemp "${MIHOMO_BASE_DIR}/.mixin.update.XXXXXX") || return 1
    cp -p "$MIHOMO_CONFIG_MIXIN" "$staged_mixin" || {
        rm -f "$staged_mixin"
        return 1
    }
    if ! "$BIN_YQ" -i "$expression" "$staged_mixin"; then
        rm -f "$staged_mixin"
        return 1
    fi
    _apply_config_transaction "$MIHOMO_CONFIG_RAW" "$staged_mixin"
    local status=$?
    rm -f "$staged_mixin"
    return "$status"
}

_merge_config_restart() {
    _apply_config_transaction "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN"
}

function clashsecret() {
    case "$#" in
    0)
        if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
            _okcat "当前密钥：$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)"
        else
            _failcat "运行时配置文件不存在"
        fi
        ;;
    1)
        local SECRET_VALUE=$1
        export SECRET_VALUE
        _update_mixin_transaction '.secret = strenv(SECRET_VALUE)' || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_tunstatus() {
    if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
        local tun_status=$("$BIN_YQ" '.tun.enable' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        # shellcheck disable=SC2015
        [ "$tun_status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
    else
        _failcat 'Tun 状态：配置文件不存在'
        return 1
    fi
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    _update_mixin_transaction '.tun.enable = false' || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    _update_mixin_transaction '.tun.enable = true' || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    sleep 0.5s
    
    # Check if mihomo is running and tun mode is working
    if is_mihomo_running; then
        local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
        # Check recent log entries for tun mode status
        if [ -f "$log_file" ]; then
            # Look for tun-related messages in the last few lines
            tail -20 "$log_file" 2>/dev/null | grep -i "tun" >/dev/null 2>&1 && {
                _okcat "Tun 模式已开启"
            } || {
                _okcat "Tun 模式已开启 (请检查日志确认状态: $log_file)"
            }
        else
            _okcat "Tun 模式已开启"
        fi
    else
        _failcat "Tun 模式配置已更新，但 mihomo 进程未运行"
    fi
}

function clashtun() {
    case "$1" in
    on)
        _tunon
        ;;
    off)
        _tunoff
        ;;
    *)
        _tunstatus
        ;;
    esac
}

_lanstatus() {
    if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
        local lan_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        if [ "$lan_status" = 'true' ]; then
            _okcat '局域网访问：已开启'
        else
            _failcat '局域网访问：已关闭'
        fi
    else
        _failcat '局域网访问：配置文件不存在'
        return 1
    fi
}

_lanoff() {
    _lanstatus >/dev/null 2>&1 && {
        local current_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        [ "$current_status" = 'false' ] && return 0
    }

    _update_mixin_transaction '.allow-lan = false' || {
        _failcat "无法更新局域网访问配置"
        return 1
    }
    _okcat "局域网访问已关闭"
}

_lanon() {
    local current_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
    [ "$current_status" = 'true' ] && return 0

    _update_mixin_transaction '.allow-lan = true' || {
        _failcat "无法更新局域网访问配置"
        return 1
    }
    _okcat "局域网访问已开启"
}

function clashlan() {
    case "$1" in
    on)
        _lanon
        ;;
    off)
        _lanoff
        ;;
    status)
        _lanstatus
        ;;
    *)
        _lanstatus
        ;;
    esac
}

function clashsubscribe() {
    case "$#" in
    0)
        # Show current subscription URL
        local url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
        if [ -n "$url" ]; then
            _okcat "当前订阅地址: $url"
        else
            _failcat "未设置订阅地址"
            return 1
        fi
        ;;
    1)
        # Set new subscription URL
        local new_url="$1"
        if [ "${new_url:0:4}" != "http" ]; then
            _failcat "无效的订阅地址，必须以 http 或 https 开头"
            return 1
        fi
        
        # Save URL
        mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
        echo "$new_url" > "$MIHOMO_CONFIG_URL"
        _okcat "订阅地址已设置: $new_url"
        
        # Ask if user wants to update immediately
        printf "是否立即更新订阅配置? [y/N]: "
        read -r response
        case "$response" in
        [yY]|[yY][eE][sS])
            clashupdate "$new_url"
            ;;
        *)
            _okcat "订阅地址已保存，使用 'clash update' 命令更新配置"
            ;;
        esac
        ;;
    *)
        cat <<EOF
用法: clash subscribe [URL]
    无参数      显示当前订阅地址
    URL         设置新的订阅地址
EOF
        ;;
    esac
}

function clashupdate() {
    case "$1" in
    app | self | program)
        shift
        clashappupdate "$@"
        return $?
        ;;
    kernel | mihomo)
        shift
        clashmihomo update "$@"
        return $?
        ;;
    config | subscription)
        shift
        ;;
    esac

    local url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    local is_auto auto_action

    case "$1" in
    auto)
        is_auto=true
        case "${2:-on}" in
        on | enable)
            auto_action=on
            [ -n "$3" ] && url=$3
            ;;
        off | disable)
            auto_action=off
            ;;
        status)
            auto_action=status
            ;;
        http://* | https://*)
            # Backward compatibility: clash update auto URL
            auto_action=on
            url=$2
            ;;
        *)
            _failcat "用法: clash update auto [on|off|status] [URL]"
            return 1
            ;;
        esac
        ;;
    log)
        tail "${MIHOMO_UPDATE_LOG}" 2>/dev/null || _failcat "暂无更新日志"
        return 0
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # 自动更新只适用于已保存的 HTTP(S) 订阅地址。
    if [ "$is_auto" = true ]; then
        command -v crontab >/dev/null 2>&1 || {
            _failcat "系统未安装 crontab，无法管理订阅自动更新"
            return 1
        }

        case "$auto_action" in
        off)
            if crontab -l 2>/dev/null | grep -qs 'mihomoctl_auto_update'; then
                local remaining_crontab
                remaining_crontab=$(crontab -l 2>/dev/null | grep -v 'mihomoctl_auto_update' || true)
                if [ -n "$remaining_crontab" ]; then
                    printf '%s\n' "$remaining_crontab" | crontab - || return 1
                else
                    crontab -r 2>/dev/null || true
                fi
                _okcat "已关闭订阅自动更新；现有订阅配置保持不变"
            else
                _okcat "订阅自动更新当前未开启"
            fi
            return 0
            ;;
        status)
            if crontab -l 2>/dev/null | grep -qs 'mihomoctl_auto_update'; then
                _okcat "订阅自动更新：开启（每2天执行一次）"
            else
                _okcat "订阅自动更新：关闭"
            fi
            return 0
            ;;
        esac

        case "$url" in
        http://* | https://*) ;;
        *)
            _failcat "未设置有效订阅地址，请先执行 clash subscribe URL"
            return 1
            ;;
        esac

        # Persist URL for cron runs (cron executes `mihomoctl update`, which reads MIHOMO_CONFIG_URL).
        mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
        printf '%s\n' "$url" > "$MIHOMO_CONFIG_URL"

        # Add one user-level crontab entry (every 2 days at midnight).
        if ! crontab -l 2>/dev/null | grep -qs 'mihomoctl_auto_update'; then
            (crontab -l 2>/dev/null || true; echo "0 0 */2 * * $_SHELL -i -c 'mihomoctl update' # mihomoctl_auto_update") | crontab - || return 1
        fi
        _okcat "已开启订阅自动更新（每2天执行一次）"
        _okcat "关闭命令：clash update auto off"
        return 0
    fi

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    [ "${url:0:4}" != "http" ] && {
        _failcat "没有提供有效的订阅链接：使用 ${MIHOMO_CONFIG_RAW} 进行更新..."
        url="file://$MIHOMO_CONFIG_RAW"
    }

    _okcat '👌' "正在下载：现有配置将在新配置验证通过后替换..."

    local staged_raw
    mkdir -p "$(dirname "$MIHOMO_CONFIG_RAW_BAK")" "$(dirname "$MIHOMO_UPDATE_LOG")"
    staged_raw=$(mktemp "${MIHOMO_BASE_DIR}/.subscription.update.XXXXXX") || return 1
    if [ "${url:0:5}" = "file:" ]; then
        cp -p "$MIHOMO_CONFIG_RAW" "$staged_raw" || {
            rm -f "$staged_raw"
            return 1
        }
    elif ! _download_config "$staged_raw" "$url"; then
        rm -f "$staged_raw"
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" >> "${MIHOMO_UPDATE_LOG}"
        _failcat '🍂' "下载或转换失败，现有配置未改动；转换日志：$BIN_SUBCONVERTER_LOG"
        return 1
    fi
    if ! _valid_config "$staged_raw"; then
        rm -f "$staged_raw"
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" >> "${MIHOMO_UPDATE_LOG}"
        _failcat '🍂' "新配置校验失败，现有配置未改动；转换日志：$BIN_SUBCONVERTER_LOG"
        return 1
    fi

    cp -p "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_RAW_BAK" 2>/dev/null || {
        rm -f "$staged_raw"
        _failcat "原配置备份失败，更新已取消"
        return 1
    }
    if ! _apply_config_transaction "$staged_raw" "$MIHOMO_CONFIG_MIXIN"; then
        rm -f "$staged_raw"
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" >> "${MIHOMO_UPDATE_LOG}"
        return 1
    fi
    rm -f "$staged_raw"
    _okcat '🍃' '订阅更新成功'
    
    # Save URL and log success using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
    echo "$url" > "$MIHOMO_CONFIG_URL"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新成功：$url" >> "${MIHOMO_UPDATE_LOG}"
}

_download_app_file() {
    local path=$1
    local dest=$2
    local revision=$3
    local url="https://raw.githubusercontent.com/${CLASH_LAB_KIT_REPO}/${revision}/${path}"
    local cache_bust proxy_url
    cache_bust=$(date +%s)
    proxy_url="${URL_GH_PROXY}/${url}?v=${cache_bust}"

    # Prefer the canonical source so an accelerator cannot return stale code.
    if curl --silent --show-error --fail --location --connect-timeout 15 --max-time 60 --retry 2 \
        --output "$dest" "${url}?v=${cache_bust}"; then
        return 0
    fi

    curl --silent --show-error --fail --location --connect-timeout 15 --max-time 60 --retry 2 \
        --output "$dest" "$proxy_url"
}

_verify_app_file_sha256() {
    local file=$1
    local expected=$2
    local actual

    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') || return 1
    [ "$actual" = "$expected" ]
}

_safe_app_manifest_path() {
    local source=$1
    local target=$2

    case "$source" in
    script/* | resources/* | third_party/licenses/* | LICENSE | THIRD_PARTY_NOTICES.md) ;;
    *) return 1 ;;
    esac
    case "$target" in
    script/* | config/templates/* | licenses/* | Country.mmdb | LICENSE | THIRD_PARTY_NOTICES.md) ;;
    *) return 1 ;;
    esac
    case "/$source/$target/" in
    *'/../'* | *'/./'* | *'//'*) return 1 ;;
    esac
    case "$source$target" in
    *[[:space:]]*) return 1 ;;
    esac
}

_valid_app_version() {
    printf '%s\n' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
}

_app_version_is_older() {
    local target=$1
    local current=$2
    local oldest

    _valid_app_version "$target" && _valid_app_version "$current" || return 1
    [ "$target" != "$current" ] || return 1
    oldest=$(printf '%s\n%s\n' "$target" "$current" | LC_ALL=C sort -V | head -n1) || return 1
    [ "$oldest" = "$target" ]
}

_prepare_manifest_app_files() {
    local manifest=$1
    local revision=$2
    local update_dir=$3
    local app_version change_count first_change_version count index source target expected mode staged

    [ "$("$BIN_YQ" -r '.manifest-version // 0' "$manifest" 2>/dev/null)" = 1 ] || return 1
    [ "$("$BIN_YQ" -r '.config-schema-version // 0' "$manifest" 2>/dev/null)" = 1 ] || return 1
    app_version=$("$BIN_YQ" -r '.app-version // ""' "$manifest" 2>/dev/null) || return 1
    _valid_app_version "$app_version" || return 1
    change_count=$("$BIN_YQ" -r '(.user-facing-changes // []) | length' "$manifest" 2>/dev/null) || return 1
    case "$change_count" in
    '' | *[!0-9]*) return 1 ;;
    esac
    [ "$change_count" -gt 0 ] || return 1
    first_change_version=$("$BIN_YQ" -r '.user-facing-changes[0].version // ""' "$manifest" 2>/dev/null) || return 1
    [ "$first_change_version" = "$app_version" ] || return 1
    count=$("$BIN_YQ" -r '.files | length' "$manifest" 2>/dev/null) || return 1
    case "$count" in
    '' | *[!0-9]*) return 1 ;;
    esac
    [ "$count" -gt 0 ] || return 1

    mkdir -p "$update_dir/files"
    : > "$update_dir/entries"
    index=0
    while [ "$index" -lt "$count" ]; do
        source=$("$BIN_YQ" -r ".files[$index].source // \"\"" "$manifest") || return 1
        target=$("$BIN_YQ" -r ".files[$index].target // \"\"" "$manifest") || return 1
        expected=$("$BIN_YQ" -r ".files[$index].sha256 // \"\"" "$manifest") || return 1
        mode=$("$BIN_YQ" -r ".files[$index].mode // \"0644\"" "$manifest") || return 1
        _safe_app_manifest_path "$source" "$target" || return 1
        case "$expected" in
        *[!0-9a-f]* | '') return 1 ;;
        esac
        [ ${#expected} -eq 64 ] || return 1
        case "$mode" in
        0644 | 0755) ;;
        *) return 1 ;;
        esac
        if awk -F '\t' -v wanted="$target" '$2 == wanted {found = 1} END {exit !found}' \
            "$update_dir/entries"; then
            return 1
        fi

        staged="$update_dir/files/$index"
        _download_app_file "$source" "$staged" "$revision" || return 1
        _verify_app_file_sha256 "$staged" "$expected" || return 1
        printf '%s\t%s\t%s\n' "$index" "$target" "$mode" >> "$update_dir/entries"
        index=$((index + 1))
    done

    grep -q $'\tscript/common.sh\t' "$update_dir/entries" || return 1
    grep -q $'\tscript/clashctl.sh\t' "$update_dir/entries" || return 1
}

_prepare_legacy_app_files() {
    local revision=$1
    local update_dir=$2

    mkdir -p "$update_dir/files"
    : > "$update_dir/entries"
    _download_app_file script/common.sh "$update_dir/files/0" "$revision" &&
        _download_app_file script/clashctl.sh "$update_dir/files/1" "$revision" || return 1
    printf '0\tscript/common.sh\t0644\n1\tscript/clashctl.sh\t0644\n' > "$update_dir/entries"
}

_validate_staged_app_scripts() {
    local update_dir=$1
    local common_index clashctl_index

    common_index=$(awk -F '\t' '$2 == "script/common.sh" {print $1; exit}' "$update_dir/entries")
    clashctl_index=$(awk -F '\t' '$2 == "script/clashctl.sh" {print $1; exit}' "$update_dir/entries")
    [ -n "$common_index" ] && [ -n "$clashctl_index" ] || return 1
    bash -n "$update_dir/files/$common_index" "$update_dir/files/$clashctl_index" || return 1
    grep -Fqs 'function clashappupdate()' "$update_dir/files/$clashctl_index" &&
        grep -Fqs 'function clashautostart()' "$update_dir/files/$clashctl_index"
}

_restore_app_files() {
    local update_dir=$1
    local index target mode dest staged

    while IFS=$'\t' read -r index target mode; do
        [ -n "$index" ] || continue
        dest="$MIHOMO_BASE_DIR/$target"
        if [ -f "$update_dir/backup/$index" ]; then
            mkdir -p "$(dirname "$dest")" || continue
            staged=$(mktemp "${dest}.restore.XXXXXX") || continue
            if cp -p "$update_dir/backup/$index" "$staged"; then
                mv -f "$staged" "$dest" || rm -f "$staged"
            else
                rm -f "$staged"
            fi
        elif [ -f "$update_dir/backup/$index.absent" ]; then
            rm -f "$dest"
        fi
    done < "$update_dir/entries"
}

_publish_app_files() {
    local update_dir=$1
    local index target mode dest staged

    mkdir -p "$update_dir/backup" || return 1
    while IFS=$'\t' read -r index target mode; do
        [ -n "$index" ] || continue
        dest="$MIHOMO_BASE_DIR/$target"
        if [ -e "$dest" ]; then
            cp -p "$dest" "$update_dir/backup/$index" || return 1
        else
            : > "$update_dir/backup/$index.absent" || return 1
        fi
    done < "$update_dir/entries"

    while IFS=$'\t' read -r index target mode; do
        [ -n "$index" ] || continue
        dest="$MIHOMO_BASE_DIR/$target"
        mkdir -p "$(dirname "$dest")" || {
            _restore_app_files "$update_dir"
            return 1
        }
        staged=$(mktemp "${dest}.new.XXXXXX") || {
            _restore_app_files "$update_dir"
            return 1
        }
        if ! cp "$update_dir/files/$index" "$staged" ||
            ! chmod "$mode" "$staged" || ! mv -f "$staged" "$dest"; then
            rm -f "$staged"
            _restore_app_files "$update_dir"
            return 1
        fi
    done < "$update_dir/entries"
}

_get_app_revision() {
    local git_url="https://github.com/${CLASH_LAB_KIT_REPO}.git"
    local url="https://api.github.com/repos/${CLASH_LAB_KIT_REPO}/commits/${CLASH_LAB_KIT_BRANCH}"
    local response revision

    # GitHub's unauthenticated REST API can be rate-limited or blocked while
    # normal Git and Raw access still work. Resolve the branch through Git
    # first, then keep the API paths as fallbacks.
    if command -v git >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            revision=$(GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote "$git_url" \
                "refs/heads/${CLASH_LAB_KIT_BRANCH}" 2>/dev/null | awk 'NR == 1 {print $1}')
        else
            revision=$(GIT_TERMINAL_PROMPT=0 git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 \
                ls-remote "$git_url" "refs/heads/${CLASH_LAB_KIT_BRANCH}" 2>/dev/null |
                awk 'NR == 1 {print $1}')
        fi
        if [ ${#revision} -eq 40 ]; then
            printf '%s\n' "$revision"
            return 0
        fi
    fi

    response=$(curl --silent --show-error --fail --location --connect-timeout 15 --max-time 60 --retry 2 "$url") ||
        response=$(curl --silent --show-error --fail --location --connect-timeout 15 --max-time 60 --retry 2 "${URL_GH_PROXY}/${url}") ||
        return 1
    revision=$(printf '%s\n' "$response" | sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)
    [ ${#revision} -eq 40 ] || return 1
    printf '%s\n' "$revision"
}

_get_installed_app_version() {
    local manifest="${MIHOMO_BASE_DIR}/config/app-manifest.yaml"
    local version
    [ -f "$manifest" ] || return 1
    version=$("$BIN_YQ" -r '.app-version // ""' "$manifest" 2>/dev/null) || return 1
    _valid_app_version "$version" || return 1
    printf '%s\n' "$version"
}

_get_installed_app_revision() {
    local revision_file="${MIHOMO_BASE_DIR}/config/app-revision"
    [ -s "$revision_file" ] || return 1
    sed -n '1p' "$revision_file"
}

_short_app_revision() {
    local revision=$1
    [ -n "$revision" ] || return 1
    printf '%.12s\n' "$revision"
}

_show_app_update_changes() {
    local previous_version=$1
    local manifest=$2
    local count index version item_count item_index item

    [ -f "$manifest" ] || return 0
    count=$("$BIN_YQ" -r '(.user-facing-changes // []) | length' "$manifest" 2>/dev/null) || return 0
    case "$count" in
    '' | *[!0-9]*) return 0 ;;
    esac

    index=0
    while [ "$index" -lt "$count" ]; do
        version=$("$BIN_YQ" -r ".user-facing-changes[$index].version // \"\"" "$manifest" 2>/dev/null) || break
        [ -n "$previous_version" ] && [ "$version" = "$previous_version" ] && break
        item_count=$("$BIN_YQ" -r "(.user-facing-changes[$index].items // []) | length" "$manifest" 2>/dev/null) || break
        case "$item_count" in
        '' | *[!0-9]*) break ;;
        esac
        if [ "$item_count" -gt 0 ]; then
            _okcat "${version} 更新："
            item_index=0
            while [ "$item_index" -lt "$item_count" ]; do
                item=$("$BIN_YQ" -r ".user-facing-changes[$index].items[$item_index] // \"\"" "$manifest" 2>/dev/null) || break
                [ -n "$item" ] && printf '%s\n' "  - $item"
                item_index=$((item_index + 1))
            done
        fi
        index=$((index + 1))
    done
}

function clashversion() {
    local version revision
    version=$(_get_installed_app_version 2>/dev/null) || version="${CLASH_LAB_KIT_BASE_RELEASE:-旧版（未记录）}"
    revision=$(_get_installed_app_revision 2>/dev/null) || revision=""

    _okcat "Clash Lab Kit 版本：$version"
    if [ -n "$revision" ]; then
        _okcat "程序提交：$(_short_app_revision "$revision")"
    else
        _okcat "程序提交：安装包或旧版未记录"
    fi
}

function clashappupdate() {
    local update_dir backup_dir revision manifest_index revision_index
    local previous_version previous_version_display previous_revision target_version used_manifest=false
    local reload_success_message
    previous_version=$(_get_installed_app_version 2>/dev/null) || previous_version=""
    previous_version_display=${previous_version:-${CLASH_LAB_KIT_BASE_RELEASE:-旧版（未记录）}}
    previous_revision=$(_get_installed_app_revision 2>/dev/null) || previous_revision=""
    update_dir=$(mktemp -d "${TMPDIR:-/tmp}/clash-lab-kit-update.XXXXXX") || return 1
    backup_dir="${MIHOMO_BASE_DIR}/config/script-backup"

    _okcat "正在更新 Clash Lab Kit 程序..."
    revision=$(_get_app_revision) || {
        rm -rf "$update_dir"
        _failcat "无法获取 GitHub 最新版本，现有安装未改动"
        return 1
    }

    if _download_app_file resources/app-manifest.yaml "$update_dir/app-manifest.yaml" "$revision"; then
        target_version=$("$BIN_YQ" -r '.app-version // ""' "$update_dir/app-manifest.yaml" 2>/dev/null) || {
            rm -rf "$update_dir"
            return 1
        }
        if ! _valid_app_version "$target_version"; then
            rm -rf "$update_dir"
            _failcat "程序更新清单中的版本号无效，现有安装未改动"
            return 1
        fi
        if [ -n "$previous_version" ] && _app_version_is_older "$target_version" "$previous_version"; then
            rm -rf "$update_dir"
            _failcat "拒绝程序降级：当前版本 $previous_version，目标版本 $target_version"
            return 1
        fi
        _prepare_manifest_app_files "$update_dir/app-manifest.yaml" "$revision" "$update_dir" || {
            rm -rf "$update_dir"
            _failcat "程序更新清单无效或文件校验失败，现有安装未改动"
            return 1
        }
        used_manifest=true
        manifest_index=$(wc -l < "$update_dir/entries")
        revision_index=$((manifest_index + 1))
        cp "$update_dir/app-manifest.yaml" "$update_dir/files/$manifest_index" || {
            rm -rf "$update_dir"
            return 1
        }
        printf '%s\n' "$revision" > "$update_dir/files/$revision_index" || {
            rm -rf "$update_dir"
            return 1
        }
        printf '%s\tconfig/app-manifest.yaml\t0644\n' "$manifest_index" >> "$update_dir/entries"
        printf '%s\tconfig/app-revision\t0644\n' "$revision_index" >> "$update_dir/entries"
    elif ! _prepare_legacy_app_files "$revision" "$update_dir"; then
        rm -rf "$update_dir"
        _failcat "程序更新下载失败，现有安装未改动"
        return 1
    fi

    _validate_staged_app_scripts "$update_dir" || {
        rm -rf "$update_dir"
        _failcat "新脚本语法检查失败，现有安装未改动"
        return 1
    }

    mkdir -p "$backup_dir" "$MIHOMO_SCRIPT_DIR" || return 1
    cp "$MIHOMO_SCRIPT_DIR/common.sh" "$backup_dir/common.sh" 2>/dev/null || true
    cp "$MIHOMO_SCRIPT_DIR/clashctl.sh" "$backup_dir/clashctl.sh" 2>/dev/null || true

    if ! _publish_app_files "$update_dir"; then
        rm -rf "$update_dir"
        _failcat "程序更新写入失败，已恢复原文件"
        return 1
    fi
    rm -rf "$update_dir"

    if [ -f "$MIHOMO_SYSTEMD_SERVICE_PATH" ] && _user_systemd_available; then
        _write_autostart_service && systemctl --user daemon-reload
    fi

    if [ "$used_manifest" = true ]; then
        _okcat "Clash Lab Kit 程序更新完成：$previous_version_display -> $target_version"
        _okcat "程序提交：${previous_revision:+$(_short_app_revision "$previous_revision") -> }$(_short_app_revision "$revision")"
        _show_app_update_changes "$previous_version" "${MIHOMO_BASE_DIR}/config/app-manifest.yaml"
    else
        _okcat "Clash Lab Kit 程序更新完成：main@$(_short_app_revision "$revision")"
    fi

    reload_success_message=$(_okcat "当前终端已自动加载新版命令")
    if ! . "$MIHOMO_SCRIPT_DIR/common.sh" || ! . "$MIHOMO_SCRIPT_DIR/clashctl.sh"; then
        printf '%s\n' "程序文件已更新，但当前终端加载新版命令失败" >&2
        return 1
    fi
    if ! _set_rc >/dev/null 2>&1; then
        printf '%s\n' "程序已更新，但 Bash 启动配置同步失败，请检查 ~/.bashrc 写权限" >&2
    fi
    printf '%s\n' "$reload_success_message"
}

function clashmihomo() {
    local action=$1
    shift || true

    case "$action" in
    "" | version)
        if [ -x "$BIN_MIHOMO" ]; then
            "$BIN_MIHOMO" -v
        else
            _failcat "未找到已安装的 mihomo 内核: $BIN_MIHOMO"
            return 1
        fi
        ;;
    update)
        local arch version url restart_after=true was_running=false downloaded
        arch=$(uname -m)
        version="latest"
        url=""

        while [ $# -gt 0 ]; do
            case "$1" in
            --version)
                version=$2
                shift 2
                ;;
            --url)
                url=$2
                shift 2
                ;;
            --no-restart)
                restart_after=false
                shift
                ;;
            http://* | https://*)
                url=$1
                shift
                ;;
            *)
                version=$1
                shift
                ;;
            esac
        done

        mkdir -p "$ZIP_BASE_DIR"

        if [ -n "$url" ]; then
            downloaded="${ZIP_BASE_DIR}/$(basename "$url")"
            _okcat "正在下载自定义 mihomo 内核..."
            curl --progress-bar --show-error --fail --location --connect-timeout 15 --max-time 180 --retry 2 \
                --output "$downloaded" "$url" || {
                rm -f "$downloaded"
                _failcat "自定义 mihomo 下载失败"
                return 1
            }
        else
            version=$(_normalize_mihomo_version "$version")
            downloaded=$(_download_mihomo "$arch" "$version") || return 1
        fi

        is_mihomo_running && was_running=true
        _replace_installed_mihomo "$downloaded" "$version" || return 1

        if [ -x "$BIN_MIHOMO" ]; then
            _okcat "当前 mihomo 版本：$("$BIN_MIHOMO" -v | head -n1)"
        fi

        if [ "$was_running" = true ] && [ "$restart_after" = true ]; then
            _okcat "检测到 mihomo 正在运行，正在重启以应用新内核..."
            if ! clashrestart; then
                _failcat "新内核启动失败，正在恢复旧内核..."
                if [ -n "$MIHOMO_KERNEL_BACKUP" ] &&
                    _restore_installed_mihomo "$MIHOMO_KERNEL_BACKUP" &&
                    clashrestart; then
                    _failcat "内核更新失败，旧内核已恢复并重新启动"
                else
                    _failcat "内核更新失败，旧内核自动恢复也未成功，请立即检查服务"
                fi
                return 1
            fi
        fi

        _okcat "mihomo 内核更新完成"
        ;;
    help | -h | --help)
        cat <<EOF
用法: clash mihomo [version|update]
    version                         查看当前 mihomo 内核版本
    update [latest|vX.Y.Z]          更新到指定或最新 mihomo 版本
    update --url URL                从自定义下载地址更新 mihomo
    update --no-restart             替换内核后不自动重启
EOF
        ;;
    *)
        _failcat "未知的 mihomo 子命令: $action"
        return 1
        ;;
    esac
}

function clashmixin() {
    case "$1" in
    -e)
        local staged_mixin
        staged_mixin=$(mktemp "${MIHOMO_BASE_DIR}/.mixin.edit.XXXXXX") || return 1
        cp -p "$MIHOMO_CONFIG_MIXIN" "$staged_mixin" || {
            rm -f "$staged_mixin"
            return 1
        }
        if vim "$staged_mixin"; then
            _apply_config_transaction "$MIHOMO_CONFIG_RAW" "$staged_mixin" &&
                _okcat "配置更新成功，已重启生效"
            local status=$?
            rm -f "$staged_mixin"
            return "$status"
        fi
        rm -f "$staged_mixin"
        return 1
        ;;
    -r)
        less -f "$MIHOMO_CONFIG_RUNTIME"
        ;;
    *)
        less -f "$MIHOMO_CONFIG_MIXIN"
        ;;
    esac
}

_operation_requires_lock() {
    local command=$1
    local action=$2

    case "$command" in
    "" | help | -h | --help | ui | status | version)
        return 1
        ;;
    port | tun | lan | autostart)
        [ -n "$action" ] && [ "$action" != status ]
        ;;
    proxy)
        [ "$action" != status ]
        ;;
    mixin)
        [ "$action" = -e ]
        ;;
    secret | subscribe)
        [ -n "$action" ]
        ;;
    update)
        case "$action" in
        log) return 1 ;;
        auto)
            [ "${3:-on}" != status ]
            ;;
        *) return 0 ;;
        esac
        ;;
    mihomo)
        [ -n "$action" ] && [ "$action" != version ]
        ;;
    *)
        return 0
        ;;
    esac
}

_with_operation_lock() {
    if [ "${MIHOMO_SYSTEMD_RUN:-0}" = 1 ] || [ "${MIHOMO_OPERATION_LOCK_DEPTH:-0}" -gt 0 ]; then
        "$@"
        return $?
    fi

    if ! command -v flock >/dev/null 2>&1; then
        [ "${MIHOMO_FLOCK_WARNING_SHOWN:-0}" = 1 ] ||
            _failcat "系统未安装 flock，本次操作无法启用并发保护"
        MIHOMO_FLOCK_WARNING_SHOWN=1
        "$@"
        return $?
    fi

    mkdir -p "$MIHOMO_BASE_DIR/config" || return 1
    exec 9>"${MIHOMO_BASE_DIR}/config/operation.lock" || return 1
    if ! flock -n 9; then
        exec 9>&-
        _failcat "另一项 Clash 变更操作正在进行，请稍后重试"
        return 1
    fi

    MIHOMO_OPERATION_LOCK_DEPTH=1
    "$@"
    local status=$?
    MIHOMO_OPERATION_LOCK_DEPTH=0
    flock -u 9 2>/dev/null || true
    exec 9>&-
    return "$status"
}

function _clashctl_dispatch() {
    case "$1" in
    version)
        clashversion
        ;;
    on)
        clashon
        ;;
    off)
        clashoff
        ;;
    refresh)
        shift
        clashrefresh "$@"
        ;;
    hkkill)
        clashhkkill
        ;;
    hkkillpro)
        clashhkkillpro
        ;;
    restart)
        clashrestart
        ;;
    ui)
        clashui
        ;;
    status)
        shift
        clashstatus "$@"
        ;;
    proxy)
        shift
        clashproxy "$@"
        ;;
    port)
        shift
        clashport "$@"
        ;;
    tun)
        shift
        clashtun "$@"
        ;;
    lan)
        shift
        clashlan "$@"
        ;;
    mixin)
        shift
        clashmixin "$@"
        ;;
    secret)
        shift
        clashsecret "$@"
        ;;
    subscribe)
        shift
        clashsubscribe "$@"
        ;;
    update)
        shift
        clashupdate "$@"
        ;;
    autostart)
        shift
        clashautostart "$@"
        ;;
    mihomo)
        shift
        clashmihomo "$@"
        ;;
    *)
        cat <<EOF

Usage:
    clash COMMAND  [OPTION]
    mihomo COMMAND [OPTION]
    mihomoctl COMMAND [OPTION]

Commands:
    version                 查看 Clash Lab Kit 程序版本
    on                      开启代理
    off                     关闭代理
    refresh [关键词]        测速并选择最快节点，可按名称筛选
    hkkill                  按名称删除香港节点并备份配置
    hkkillpro               检测并删除 OpenAI 地区受限节点
    restart                 重启代理服务
    status                  进程运行状态
    ui                      Web 控制台地址
    proxy    [reload|off|status]   刷新、关闭或查看当前终端代理
    port     [status|auto|set]     代理端口模式设置
    tun      [on|off|status]       Tun 模式 (需要权限)
    lan      [on|off|status]       局域网访问控制
    mixin    [-e|-r]        Mixin 配置文件
    secret   [SECRET]       Web 控制台密钥
    subscribe [URL]         设置或查看订阅地址
    update   [auto|log]     更新订阅配置；auto 支持 on|off|status
    update   app            更新 Clash Lab Kit 程序
    update   kernel         更新 Mihomo 内核
    autostart [on|off|status] 登录后自动启动
    mihomo   [version|update] 管理 mihomo 内核

说明:
    • 用户空间运行，无需 sudo 权限
    • 配置目录: ~/tools/mihomo/
    • 日志目录: ~/tools/mihomo/logs/
    • 进程管理: 基于 PID 文件和 nohup

EOF
        ;;
    esac
}

function clashctl() {
    if _operation_requires_lock "$@"; then
        _with_operation_lock _clashctl_dispatch "$@"
    else
        _clashctl_dispatch "$@"
    fi
}

function mihomoctl() {
    clashctl "$@"
}

function clash() {
    clashctl "$@"
}

function mihomo() {
    clashctl "$@"
}

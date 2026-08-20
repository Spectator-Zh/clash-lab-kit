# shellcheck disable=SC2148
# shellcheck disable=SC2155

_configure_url_test_groups() {
    local config_file="$1"

    [ -f "$config_file" ] || return 0
    "$BIN_YQ" -i '
        (.proxy-groups[] | select(.type == "url-test")) |= (
            .url = "https://chatgpt.com/cdn-cgi/trace" |
            .interval = 300 |
            .lazy = false |
            .tolerance = 0
        )
    ' "$config_file" 2>/dev/null || {
        _failcat "无法更新自动选择健康检查配置"
        return 1
    }
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
    "$BIN_YQ" -i '.system-proxy.enable = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
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
    "$BIN_YQ" -i '.system-proxy.enable = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
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
ExecStart=/bin/bash -lc 'MIHOMO_SYSTEMD_RUN=1 clash on'
ExecStop=/bin/bash -lc 'MIHOMO_SYSTEMD_RUN=1 clash off'
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

    # Keep URL-test groups responsive even after a subscription refresh.
    _configure_url_test_groups "$MIHOMO_CONFIG_RAW" || return 1
    
    # Merge configuration using user permissions
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"
    
    # 检查端口冲突并显示分配结果
    _resolve_port_conflicts "$MIHOMO_CONFIG_RUNTIME" true
    
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
    mv -f "$staged" "$MIHOMO_CONFIG_RAW" || {
        rm -f "$staged"
        _failcat "无法替换配置，原配置仍保存在：$backup"
        return 1
    }

    if [ "$was_running" = true ] && ! _merge_config_restart; then
        cp -p "$backup" "$MIHOMO_CONFIG_RAW"
        _failcat "应用配置失败，已恢复原配置"
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

_merge_config_restart() {
    # Use user-accessible temp directory instead of /tmp
    local backup="${MIHOMO_BASE_DIR}/config/runtime.backup"
    
    # Ensure config directory exists
    mkdir -p "$(dirname "$backup")"
    
    # Backup current runtime config
    cat "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null > "$backup"

    # Preserve the local health-check policy after subscription updates.
    _configure_url_test_groups "$MIHOMO_CONFIG_RAW" || return 1
    
    # Merge configurations using user permissions
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"
    
    # Validate merged configuration
    _valid_config "$MIHOMO_CONFIG_RUNTIME" || {
        # Restore backup on validation failure
        cat "$backup" > "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null
        _error_quit "验证失败：请检查 Mixin 配置"
    }
    
    # Clean up backup file
    rm -f "$backup"
    
    clashrestart
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
        # Ensure mixin config directory exists
        mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
        "$BIN_YQ" -i ".secret = \"$1\"" "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config_restart
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
    # Ensure mixin config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.tun.enable = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    _merge_config_restart && _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    # Ensure mixin config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.tun.enable = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    _merge_config_restart
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

    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.allow-lan = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新局域网访问配置"
        return 1
    }
    _merge_config_restart && _okcat "局域网访问已关闭"
}

_lanon() {
    local current_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
    [ "$current_status" = 'true' ] && return 0

    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.allow-lan = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新局域网访问配置"
        return 1
    }
    _merge_config_restart && _okcat "局域网访问已开启"
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
    local is_auto

    case "$1" in
    auto)
        is_auto=true
        [ -n "$2" ] && url=$2
        ;;
    log)
        tail "${MIHOMO_UPDATE_LOG}" 2>/dev/null || _failcat "暂无更新日志"
        return 0
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    [ "${url:0:4}" != "http" ] && {
        _failcat "没有提供有效的订阅链接：使用 ${MIHOMO_CONFIG_RAW} 进行更新..."
        url="file://$MIHOMO_CONFIG_RAW"
    }

    # 如果是自动更新模式，则设置用户级定时任务
    [ "$is_auto" = true ] && {
        # Persist URL for cron runs (cron executes `mihomoctl update`, which reads MIHOMO_CONFIG_URL).
        [ "${url:0:4}" = "http" ] && {
            mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
            echo "$url" > "$MIHOMO_CONFIG_URL"
        }

        # Check if crontab entry already exists
        crontab -l 2>/dev/null | grep -qs 'mihomoctl_auto_update' || {
            # Add user-level crontab entry (every 2 days at midnight)
            (crontab -l 2>/dev/null; echo "0 0 */2 * * $_SHELL -i -c 'mihomoctl update' # mihomoctl_auto_update") | crontab -
        }
        _okcat "已设置用户级定时更新订阅 (每2天执行一次)" && return 0
    }

    _okcat '👌' "正在下载：原配置已备份..."
    
    # Ensure directories exist and backup using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_RAW_BAK")" "$(dirname "$MIHOMO_UPDATE_LOG")"
    cp "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_RAW_BAK" 2>/dev/null

    _rollback() {
        _failcat '🍂' "$1"
        # Restore backup using user permissions
        cp "$MIHOMO_CONFIG_RAW_BAK" "$MIHOMO_CONFIG_RAW" 2>/dev/null
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" >> "${MIHOMO_UPDATE_LOG}"
        return 1
    }

    _download_config "$MIHOMO_CONFIG_RAW" "$url" || { _rollback "下载失败：已回滚配置" || true; return 1; }
    _valid_config "$MIHOMO_CONFIG_RAW" || { _rollback "转换失败：已回滚配置，转换日志：$BIN_SUBCONVERTER_LOG" || true; return 1; }

    _merge_config_restart || return 1
    _okcat '🍃' '订阅更新成功'
    
    # Save URL and log success using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
    echo "$url" > "$MIHOMO_CONFIG_URL"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新成功：$url" >> "${MIHOMO_UPDATE_LOG}"
}

_download_app_script() {
    local name=$1
    local dest=$2
    local revision=$3
    local url="https://raw.githubusercontent.com/${CLASH_LAB_KIT_REPO}/${revision}/script/${name}"
    local cache_bust proxy_url
    cache_bust=$(date +%s)
    proxy_url="${URL_GH_PROXY}/${url}?v=${cache_bust}"

    # Prefer the canonical source so an accelerator cannot return stale code.
    if curl --silent --show-error --fail --location --connect-timeout 15 --retry 2 \
        --output "$dest" "${url}?v=${cache_bust}"; then
        return 0
    fi

    curl --silent --show-error --fail --location --connect-timeout 15 --retry 2 \
        --output "$dest" "$proxy_url"
}

_get_app_revision() {
    local git_url="https://github.com/${CLASH_LAB_KIT_REPO}.git"
    local url="https://api.github.com/repos/${CLASH_LAB_KIT_REPO}/commits/${CLASH_LAB_KIT_BRANCH}"
    local response revision

    # GitHub's unauthenticated REST API can be rate-limited or blocked while
    # normal Git and Raw access still work. Resolve the branch through Git
    # first, then keep the API paths as fallbacks.
    if command -v git >/dev/null 2>&1; then
        revision=$(git ls-remote "$git_url" "refs/heads/${CLASH_LAB_KIT_BRANCH}" 2>/dev/null |
            awk 'NR == 1 {print $1}')
        if [ ${#revision} -eq 40 ]; then
            printf '%s\n' "$revision"
            return 0
        fi
    fi

    response=$(curl --silent --show-error --fail --location --connect-timeout 15 --retry 2 "$url") ||
        response=$(curl --silent --show-error --fail --location --connect-timeout 15 --retry 2 "${URL_GH_PROXY}/${url}") ||
        return 1
    revision=$(printf '%s\n' "$response" | sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n1)
    [ ${#revision} -eq 40 ] || return 1
    printf '%s\n' "$revision"
}

function clashappupdate() {
    local update_dir backup_dir revision
    update_dir=$(mktemp -d "${TMPDIR:-/tmp}/clash-lab-kit-update.XXXXXX") || return 1
    backup_dir="${MIHOMO_BASE_DIR}/config/script-backup"

    _okcat "正在更新 Clash Lab Kit 程序..."
    revision=$(_get_app_revision) || {
        rm -rf "$update_dir"
        _failcat "无法获取 GitHub 最新版本，现有安装未改动"
        return 1
    }
    _download_app_script common.sh "$update_dir/common.sh" "$revision" &&
        _download_app_script clashctl.sh "$update_dir/clashctl.sh" "$revision" || {
            rm -rf "$update_dir"
            _failcat "程序更新下载失败，现有安装未改动"
            return 1
        }

    bash -n "$update_dir/common.sh" "$update_dir/clashctl.sh" || {
        rm -rf "$update_dir"
        _failcat "新脚本语法检查失败，现有安装未改动"
        return 1
    }

    if ! grep -Fqs 'function clashappupdate()' "$update_dir/clashctl.sh" ||
        ! grep -Fqs 'function clashautostart()' "$update_dir/clashctl.sh"; then
        rm -rf "$update_dir"
        _failcat "远端程序版本不完整或早于当前版本，现有安装未改动"
        return 1
    fi

    mkdir -p "$backup_dir" "$MIHOMO_SCRIPT_DIR" || return 1
    cp "$MIHOMO_SCRIPT_DIR/common.sh" "$backup_dir/common.sh" 2>/dev/null || true
    cp "$MIHOMO_SCRIPT_DIR/clashctl.sh" "$backup_dir/clashctl.sh" 2>/dev/null || true

    if ! cp "$update_dir/common.sh" "$MIHOMO_SCRIPT_DIR/common.sh" ||
        ! cp "$update_dir/clashctl.sh" "$MIHOMO_SCRIPT_DIR/clashctl.sh"; then
        cp "$backup_dir/common.sh" "$MIHOMO_SCRIPT_DIR/common.sh" 2>/dev/null || true
        cp "$backup_dir/clashctl.sh" "$MIHOMO_SCRIPT_DIR/clashctl.sh" 2>/dev/null || true
        rm -rf "$update_dir"
        _failcat "程序更新写入失败，已恢复原脚本"
        return 1
    fi
    rm -rf "$update_dir"

    if [ -f "$MIHOMO_SYSTEMD_SERVICE_PATH" ] && _user_systemd_available; then
        _write_autostart_service && systemctl --user daemon-reload
    fi

    _okcat "Clash Lab Kit 程序更新完成"
    _okcat "请重新打开终端，或执行: source ~/.bashrc"
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
            curl --progress-bar --show-error --fail --location --connect-timeout 15 --retry 2 \
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
            clashrestart || return 1
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
        vim "$MIHOMO_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less -f "$MIHOMO_CONFIG_RUNTIME"
        ;;
    *)
        less -f "$MIHOMO_CONFIG_MIXIN"
        ;;
    esac
}

function clashctl() {
    case "$1" in
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
    update   [auto|log]     更新订阅配置
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

function mihomoctl() {
    clashctl "$@"
}

function clash() {
    clashctl "$@"
}

function mihomo() {
    clashctl "$@"
}

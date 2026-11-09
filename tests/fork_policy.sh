#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/fixture" "$TMP_DIR/project/.claude"

cat >"$TMP_DIR/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

self_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "--version" ]; then
  printf '2.1.318 (Claude Code)\n'
  exit 0
fi

env | sort >"$self_dir/fake-claude.env"
printf '%s\n' "$@" >"$self_dir/fake-claude.args"
touch "$self_dir/fake-claude.started"
for arg in "$@"; do
  if [ "$arg" = "--hold" ]; then
    sleep 60
  fi
done
EOF
chmod +x "$TMP_DIR/fake-claude"

cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

fixture="${HOME}/fixture"
mkdir -p "$fixture"
out=""
prev=""
args=""
{
  for a in "$@"; do
    printf '%s\t' "$a"
  done
  printf '\n'
} >>"$fixture/argv.log"
for a in "$@"; do
  if [ "$prev" = "-o" ]; then
    out="$a"
  fi
  prev="$a"
  args="${args} ${a}"
done

emit() {
  if [ -n "$out" ]; then
    cat >"$out"
  else
    cat
  fi
}

if printf '%s' "$args" | grep -Eq '(^| )-6( |$)'; then
  exit 7
fi

if printf '%s' "$args" | grep -q '/cdn-cgi/trace'; then
  count=0
  if [ -f "$fixture/ip-count" ]; then
    count="$(cat "$fixture/ip-count")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" >"$fixture/ip-count"
  mode="allow"
  if [ -f "$fixture/ip-mode" ]; then
    mode="$(cat "$fixture/ip-mode")"
  fi
  ip="203.0.113.10"
  case "$mode" in
    deny) ip="198.51.100.20" ;;
    drift)
      if [ "$count" -gt 1 ]; then
        ip="198.51.100.55"
      fi
      ;;
  esac
  emit <<BODY
h=api.anthropic.com
ip=${ip}
visit_scheme=https
BODY
  exit 0
fi

if printf '%s' "$args" | grep -q '/configs'; then
  emit <"$fixture/configs.json"
  exit 0
fi
if printf '%s' "$args" | grep -q '/proxies'; then
  emit <"$fixture/proxies.json"
  exit 0
fi
if printf '%s' "$args" | grep -q '/rules'; then
  emit <"$fixture/rules.json"
  exit 0
fi
if printf '%s' "$args" | grep -q '/connections'; then
  emit <"$fixture/connections.json"
  exit 0
fi

if printf '%s' "$args" | grep -q 'https://api.anthropic.com/'; then
  {
    printf '* CONNECT api.anthropic.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Google Trust Services; CN=WE1\n'
  } >&2
  exit 0
fi
if printf '%s' "$args" | grep -q 'https://platform.claude.com/'; then
  {
    printf '* CONNECT platform.claude.com:443 HTTP/1.1\n'
    printf '* CONNECT tunnel established\n'
    printf '* SSL certificate verify ok.\n'
    printf '*  issuer: C=US; O=Let'\''s Encrypt; CN=YE1\n'
  } >&2
  exit 0
fi
exit 1
EOF
chmod +x "$TMP_DIR/bin/curl"

cat >"$TMP_DIR/home/fixture/configs.json" <<'EOF'
{
  "tun": {"enable": true, "stack": "gVisor", "strict-route": false},
  "dns": {"enhanced-mode": "fake-ip"},
  "ipv6": false
}
EOF
cat >"$TMP_DIR/home/fixture/proxies.json" <<'EOF'
{
  "proxies": {
    "ClaudeAI": {
      "type": "Selector",
      "now": "lisa-VLESS_WS",
      "all": ["lisa-VLESS_WS", "DIRECT", "REJECT"]
    },
    "lisa-VLESS_WS": {"type": "Vless"},
    "DIRECT": {"type": "Direct"},
    "REJECT": {"type": "Reject"}
  }
}
EOF
cat >"$TMP_DIR/home/fixture/rules.json" <<'EOF'
{
  "rules": [
    {"type": "DomainSuffix", "payload": "anthropic.com", "proxy": "ClaudeAI"},
    {"type": "DomainSuffix", "payload": "claude.ai", "proxy": "ClaudeAI"},
    {"type": "Match", "payload": "", "proxy": "Proxy"}
  ]
}
EOF
printf '{"connections":[]}\n' >"$TMP_DIR/home/fixture/connections.json"
printf 'allow\n' >"$TMP_DIR/home/fixture/ip-mode"
printf 'fake ca\n' >"$TMP_DIR/cert.pem"

cat >"$TMP_DIR/settings-hooks.json" <<'EOF'
{
  "disableAllHooks": false,
  "disableAgentView": false,
  "disableWorkflows": false,
  "enabledPlugins": {"codex@openai-codex": true},
  "env": {}
}
EOF
printf '{}\n' >"$TMP_DIR/settings-empty.json"

cat >"$TMP_DIR/config.json" <<EOF
{
  "command": "$TMP_DIR/fake-claude",
  "config_dir": "$TMP_DIR/home/profile",
  "allowed_ips": ["203.0.113.10"],
  "strict_lifecycle": false,
  "blocked_plugins": [],
  "notify": false,
  "mihomo": {
    "group": "ClaudeAI",
    "allowed_nodes": ["lisa-VLESS_WS"],
    "strict": false
  }
}
EOF

run_guard() {
  HOME="$TMP_DIR/home" \
    PATH="$TMP_DIR/bin:$PATH" \
    CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
    CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-hooks.json" \
    CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
    CLAUDE_GUARD_ASSUME_YES=1 \
    CLAUDE_GUARD_WATCHDOG=0 \
    CLAUDE_GUARD_UI=never \
    CLAUDE_GUARD_IP_RETRIES=1 \
    CLAUDE_GUARD_TLS_RETRIES=1 \
    CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
    "$ROOT_DIR/bin/claude-guard" "$@"
}

rm -f "$TMP_DIR/home/fixture/argv.log" "$TMP_DIR/home/fixture/ip-count"
if ! run_guard --precheck-only >"$TMP_DIR/warn.out" 2>&1; then
  cat "$TMP_DIR/warn.out" >&2
  printf 'warn-only lifecycle precheck failed\n' >&2
  exit 1
fi
grep -q '生命周期警告' "$TMP_DIR/warn.out"
grep -q 'IP 检查通过：203.0.113.10' "$TMP_DIR/warn.out"
grep -q '出口探测与 API 同路径：https://api.anthropic.com/cdn-cgi/trace 经由 http://127.0.0.1:7897' "$TMP_DIR/warn.out"
grep -q 'version=unpinned' "$TMP_DIR/warn.out"
if grep -q '已拒绝启动' "$TMP_DIR/warn.out"; then
  printf 'warn-only precheck rejected a hooks-enabled profile\n' >&2
  exit 1
fi

# Egress probe must go through the configured proxy, same host as API traffic.
if ! awk -F '\t' '
  {
    trace = 0
    proxy = 0
    for (i = 1; i <= NF; i++) {
      if ($i ~ /cdn-cgi\/trace/) trace = 1
      if ($i == "-x" && $(i + 1) == "http://127.0.0.1:7897") proxy = 1
    }
    if (trace && !proxy) { bad = 1 }
    if (trace) seen = 1
  }
  END { exit !(seen && !bad) }
' "$TMP_DIR/home/fixture/argv.log"; then
  printf 'egress probe did not use the configured proxy\n' >&2
  exit 1
fi

rm -f "$TMP_DIR/fake-claude.started"
run_guard --mark >"$TMP_DIR/launch.out" 2>&1
[ -f "$TMP_DIR/fake-claude.started" ]
if grep -q '^CLAUDE_CODE_DISABLE_AGENT_VIEW=' "$TMP_DIR/fake-claude.env"; then
  printf 'warn mode injected a lifecycle blocker\n' >&2
  exit 1
fi
if grep -q '^CLAUDE_CODE_DISABLE_WORKFLOWS=' "$TMP_DIR/fake-claude.env"; then
  printf 'warn mode injected workflow blocker\n' >&2
  exit 1
fi
grep -qx 'DISABLE_UPDATES=1' "$TMP_DIR/fake-claude.env"

if HOME="$TMP_DIR/home" \
  PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-missing.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  CLAUDE_GUARD_ASSUME_YES=1 \
  CLAUDE_GUARD_WATCHDOG=0 \
  CLAUDE_GUARD_UI=never \
  CLAUDE_GUARD_IP_RETRIES=1 \
  CLAUDE_GUARD_TLS_RETRIES=1 \
  CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >"$TMP_DIR/missing-settings.out" 2>&1; then
  :
else
  cat "$TMP_DIR/missing-settings.out" >&2
  printf 'missing settings blocked network checks\n' >&2
  exit 1
fi
grep -q 'settings 不存在' "$TMP_DIR/missing-settings.out"
grep -q 'IP 检查通过：203.0.113.10' "$TMP_DIR/missing-settings.out"

if HOME="$TMP_DIR/home" \
  PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-empty.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  CLAUDE_GUARD_ASSUME_YES=1 \
  CLAUDE_GUARD_WATCHDOG=0 \
  CLAUDE_GUARD_UI=never \
  CLAUDE_GUARD_IP_RETRIES=1 \
  CLAUDE_GUARD_TLS_RETRIES=1 \
  CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
  CLAUDE_GUARD_STRICT_LIFECYCLE=1 \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >"$TMP_DIR/strict.out" 2>&1; then
  printf 'strict lifecycle unexpectedly passed\n' >&2
  exit 1
fi
grep -q '生命周期策略' "$TMP_DIR/strict.out"
grep -q 'IP 检查通过：203.0.113.10' "$TMP_DIR/strict.out"
grep -q '网络检查已完成，已拒绝启动' "$TMP_DIR/strict.out"

printf 'deny\n' >"$TMP_DIR/home/fixture/ip-mode"
rm -f "$TMP_DIR/home/fixture/ip-count"
if run_guard --precheck-only >"$TMP_DIR/deny.out" 2>&1; then
  printf 'non-allowlisted egress unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'IP 检查失败：198.51.100.20' "$TMP_DIR/deny.out"
grep -q '出口与白名单不一致：探测到 198.51.100.20，允许 203.0.113.10。' "$TMP_DIR/deny.out"
grep -q 'https://api.anthropic.com/cdn-cgi/trace 经由代理 http://127.0.0.1:7897' "$TMP_DIR/deny.out"
grep -q '不提供 unsafe 绕过' "$TMP_DIR/deny.out"
grep -q '默认不会结束已经在跑的后台会话' "$TMP_DIR/deny.out"
printf 'allow\n' >"$TMP_DIR/home/fixture/ip-mode"

jq '.client_version = "2.1.220"' "$TMP_DIR/config.json" >"$TMP_DIR/config-pin.json"
if HOME="$TMP_DIR/home" \
  PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config-pin.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-hooks.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  CLAUDE_GUARD_UI=never \
  CLAUDE_GUARD_IP_RETRIES=1 \
  CLAUDE_GUARD_TLS_RETRIES=1 \
  CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >"$TMP_DIR/pin.out" 2>&1; then
  printf 'optional version pin unexpectedly passed\n' >&2
  exit 1
fi
grep -q '客户端版本校验失败：期望 2.1.220，实际 2.1.318。' "$TMP_DIR/pin.out"

rm -f "$TMP_DIR/home/fixture/argv.log"
if ! HOME="$TMP_DIR/home" \
  PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-hooks.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  CLAUDE_GUARD_ASSUME_YES=1 \
  CLAUDE_GUARD_WATCHDOG=0 \
  CLAUDE_GUARD_UI=never \
  CLAUDE_GUARD_IP_RETRIES=1 \
  CLAUDE_GUARD_TLS_RETRIES=1 \
  CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
  CLAUDE_GUARD_MIHOMO_API="unix:///tmp/claude-guard-mihomo.sock" \
  CLAUDE_GUARD_MIHOMO_SECRET="super-secret-mihomo" \
  "$ROOT_DIR/bin/claude-guard" doctor >"$TMP_DIR/doctor.out" 2>&1; then
  cat "$TMP_DIR/doctor.out" >&2
  printf 'doctor failed while egress was allowed\n' >&2
  exit 1
fi
grep -q 'Mihomo（只读）:' "$TMP_DIR/doctor.out"
grep -q '可达: yes' "$TMP_DIR/doctor.out"
grep -q 'tun.strict-route: false' "$TMP_DIR/doctor.out"
grep -q 'tun.strict-route 未开启' "$TMP_DIR/doctor.out"
grep -q '组内包含 DIRECT' "$TMP_DIR/doctor.out"
grep -q '选中节点: lisa-VLESS_WS' "$TMP_DIR/doctor.out"
grep -q '未命中期望组: platform.claude.com -> Proxy（期望 ClaudeAI）' "$TMP_DIR/doctor.out"
grep -q '遥测未覆盖: http-intake.logs.us5.datadoghq.com' "$TMP_DIR/doctor.out"
grep -q '已覆盖: 5/10 个必需域名' "$TMP_DIR/doctor.out"
grep -q '未写入任何配置文件或订阅' "$TMP_DIR/doctor.out"
grep -q 'strict-route: true' "$TMP_DIR/doctor.out"
grep -q 'DOMAIN-SUFFIX,anthropic.com,ClaudeAI' "$TMP_DIR/doctor.out"
grep -q '桌面端:' "$TMP_DIR/doctor.out"
grep -q 'Claude.app: 未发现进程' "$TMP_DIR/doctor.out"
grep -q '本工具不修改登录项' "$TMP_DIR/doctor.out"
grep -q 'Doctor result: PASS (Claude was not started)' "$TMP_DIR/doctor.out"
if grep -q 'super-secret-mihomo' "$TMP_DIR/doctor.out"; then
  printf 'doctor printed the mihomo secret\n' >&2
  exit 1
fi
if awk -F '\t' '
  {
    for (i = 1; i < NF; i++) {
      if ($i == "-X" && $(i + 1) ~ /^(PUT|PATCH|DELETE|POST)$/) found = 1
    }
  }
  END { exit !found }
' "$TMP_DIR/home/fixture/argv.log"; then
  printf 'mihomo query used a write method\n' >&2
  exit 1
fi
if ! awk -F '\t' '
  {
    mihomo = 0
    get = 0
    for (i = 1; i <= NF; i++) {
      if ($i ~ /\/configs$/) mihomo = 1
      if ($i == "-X" && $(i + 1) == "GET") get = 1
    }
    if (mihomo && !get) bad = 1
    if (mihomo) seen = 1
  }
  END { exit !(seen && !bad) }
' "$TMP_DIR/home/fixture/argv.log"; then
  printf 'mihomo query was not an explicit GET\n' >&2
  exit 1
fi

if HOME="$TMP_DIR/home" \
  PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-hooks.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  CLAUDE_GUARD_UI=never \
  CLAUDE_GUARD_IP_RETRIES=1 \
  CLAUDE_GUARD_TLS_RETRIES=1 \
  CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
  CLAUDE_GUARD_MIHOMO_API="unix:///tmp/claude-guard-mihomo.sock" \
  CLAUDE_GUARD_MIHOMO_STRICT=1 \
  "$ROOT_DIR/bin/claude-guard" doctor >"$TMP_DIR/mihomo-strict.out" 2>&1; then
  printf 'mihomo strict unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'mihomo 严格检查未通过' "$TMP_DIR/mihomo-strict.out"
grep -q '组内包含 DIRECT' "$TMP_DIR/mihomo-strict.out"

if HOME="$TMP_DIR/home" \
  PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-hooks.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  CLAUDE_GUARD_UI=never \
  CLAUDE_GUARD_WATCHDOG_STRICT_SIGNAL=KILL \
  "$ROOT_DIR/bin/claude-guard" --precheck-only >"$TMP_DIR/bad-signal.out" 2>&1; then
  printf 'invalid strict signal unexpectedly passed\n' >&2
  exit 1
fi
grep -q 'CLAUDE_GUARD_WATCHDOG_STRICT_SIGNAL 只能是 TERM 或 STOP' "$TMP_DIR/bad-signal.out"

printf 'drift\n' >"$TMP_DIR/home/fixture/ip-mode"
rm -f "$TMP_DIR/home/fixture/ip-count" "$TMP_DIR/observe.log"
sleep 60 &
bystander=$!
HOME="$TMP_DIR/home" \
  PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-hooks.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  CLAUDE_GUARD_ASSUME_YES=1 \
  CLAUDE_GUARD_UI=never \
  CLAUDE_GUARD_IP_RETRIES=1 \
  CLAUDE_GUARD_TLS_RETRIES=1 \
  CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
  CLAUDE_GUARD_WATCHDOG=1 \
  CLAUDE_GUARD_WATCHDOG_DRY_RUN=1 \
  CLAUDE_GUARD_WATCHDOG_STRICT=0 \
  CLAUDE_GUARD_IP_INTERVAL=1 \
  CLAUDE_GUARD_API_INTERVAL=30 \
  CLAUDE_GUARD_WATCHDOG_TICK_SECONDS=1 \
  CLAUDE_GUARD_IP_BAD_THRESHOLD=1 \
  CLAUDE_GUARD_LOG_FILE="$TMP_DIR/observe.log" \
  "$ROOT_DIR/bin/claude-guard" --hold >"$TMP_DIR/observe.out" 2>&1 &
observe_pid=$!
observed=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if [ -f "$TMP_DIR/observe.log" ] && grep -q 'existing session left running' "$TMP_DIR/observe.log"; then
    observed=1
    break
  fi
  sleep 0.2
done
if [ "$observed" -ne 1 ]; then
  printf 'observe watchdog did not record an egress hold\n' >&2
  cat "$TMP_DIR/observe.out" >&2 || true
  cat "$TMP_DIR/observe.log" >&2 || true
  kill "$observe_pid" "$bystander" 2>/dev/null || true
  exit 1
fi
if ! kill -0 "$observe_pid" 2>/dev/null; then
  printf 'observe watchdog stopped the existing session\n' >&2
  exit 1
fi
kill "$observe_pid" 2>/dev/null || true
wait "$observe_pid" 2>/dev/null || true

rm -f "$TMP_DIR/home/fixture/ip-count" "$TMP_DIR/strict-watch.log"
HOME="$TMP_DIR/home" \
  PATH="$TMP_DIR/bin:$PATH" \
  CLAUDE_GUARD_CONFIG="$TMP_DIR/config.json" \
  CLAUDE_GUARD_SETTINGS="$TMP_DIR/settings-hooks.json" \
  CLAUDE_GUARD_CA_CERT="$TMP_DIR/cert.pem" \
  CLAUDE_GUARD_ASSUME_YES=1 \
  CLAUDE_GUARD_UI=never \
  CLAUDE_GUARD_IP_RETRIES=1 \
  CLAUDE_GUARD_TLS_RETRIES=1 \
  CLAUDE_GUARD_LEGACY_PROFILE_MODE=off \
  CLAUDE_GUARD_WATCHDOG=1 \
  CLAUDE_GUARD_WATCHDOG_DRY_RUN=1 \
  CLAUDE_GUARD_WATCHDOG_STRICT=1 \
  CLAUDE_GUARD_WATCHDOG_STRICT_SIGNAL=TERM \
  CLAUDE_GUARD_IP_INTERVAL=1 \
  CLAUDE_GUARD_API_INTERVAL=30 \
  CLAUDE_GUARD_WATCHDOG_TICK_SECONDS=1 \
  CLAUDE_GUARD_IP_BAD_THRESHOLD=1 \
  CLAUDE_GUARD_LOG_FILE="$TMP_DIR/strict-watch.log" \
  "$ROOT_DIR/bin/claude-guard" --hold >"$TMP_DIR/strict-watch.out" 2>&1 &
strict_pid=$!
signaled=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [ -f "$TMP_DIR/strict-watch.log" ] && grep -q 'strict action: signal=TERM' "$TMP_DIR/strict-watch.log"; then
    signaled=1
    break
  fi
  sleep 0.2
done
if [ "$signaled" -ne 1 ]; then
  printf 'strict watchdog did not signal\n' >&2
  cat "$TMP_DIR/strict-watch.out" >&2 || true
  cat "$TMP_DIR/strict-watch.log" >&2 || true
  kill "$strict_pid" "$bystander" 2>/dev/null || true
  exit 1
fi
sleep 0.3
if kill -0 "$strict_pid" 2>/dev/null; then
  printf 'strict watchdog left the drifted session running\n' >&2
  kill "$strict_pid" "$bystander" 2>/dev/null || true
  exit 1
fi
if ! kill -0 "$bystander" 2>/dev/null; then
  printf 'strict watchdog signaled an unrelated process\n' >&2
  exit 1
fi
kill "$bystander" 2>/dev/null || true
wait "$bystander" 2>/dev/null || true
wait "$strict_pid" 2>/dev/null || true

if grep -E -q 'curl[^\\]*-X[[:space:]]*(PUT|PATCH|DELETE|POST)' "$ROOT_DIR/bin/claude-guard"; then
  printf 'claude-guard contains a mihomo write request\n' >&2
  exit 1
fi

printf 'fork policy ok\n'

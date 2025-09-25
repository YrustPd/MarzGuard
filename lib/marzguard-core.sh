#!/usr/bin/env bash
# MarzGuard core monitoring and control engine
set -euo pipefail

MG_VERSION="1.0.0"

# Global state (per process)
declare -Ag MG_CPU_WINDOWS=()
declare -Ag MG_MEM_WINDOWS=()
declare -Ag MG_LAST_ACTION_TS=()
declare -Ag MG_LAST_ACTION_DESC=()
declare -Ag MG_RESTART_COUNT_CACHE=()
declare -Ag MG_CPU_CURRENT=()
declare -Ag MG_MEM_CURRENT=()

mg_set_default() {
    local var=$1
    local value=$2
    if [[ -z ${!var:-} ]]; then
        printf -v "$var" '%s' "$value"
    fi
}

mg_try_create_file() {
    local target=$1
    if printf '' | tee "$target" >/dev/null 2>/dev/null; then
        return 0
    fi
    return 1
}

mg_prepare_dir() {
    local var=$1
    local suffix=$2
    local current=${!var}
    if [[ -d $current ]]; then
        return
    fi
    if mkdir -p "$current" 2>/dev/null; then
        return
    fi
    local base=${XDG_RUNTIME_DIR:-/tmp}
    local fallback="$base/marzguard-$suffix"
    if ! mkdir -p "$fallback" 2>/dev/null; then
        fallback="/tmp/marzguard-$suffix"
        mkdir -p "$fallback" 2>/dev/null || true
    fi
    printf -v "$var" '%s' "$fallback"
}

mg_init_paths() {
    mg_prepare_dir MG_RUNTIME_DIR runtime
    mg_prepare_dir MG_STATE_DIR state
    if [[ -e "$MG_LOG_FILE" && -w "$MG_LOG_FILE" ]]; then
        chmod 640 "$MG_LOG_FILE" 2>/dev/null || true
        return
    fi
    local logdir
    logdir=$(dirname "$MG_LOG_FILE")
    if [[ -d "$logdir" && -w "$logdir" ]]; then
        if mg_try_create_file "$MG_LOG_FILE"; then
            chmod 640 "$MG_LOG_FILE" 2>/dev/null || true
            return
        fi
    fi
    local home_dir=${HOME:-/tmp}
    local fallback="${XDG_CACHE_HOME:-$home_dir/.cache}/marzguard.log"
    local fallback_dir
    fallback_dir=$(dirname "$fallback")
    if mkdir -p "$fallback_dir" 2>/dev/null && [[ -w "$fallback_dir" ]]; then
        if mg_try_create_file "$fallback"; then
            MG_LOG_FILE=$fallback
            chmod 640 "$MG_LOG_FILE" 2>/dev/null || true
            return
        fi
    fi
    fallback="/tmp/marzguard.log"
    fallback_dir=$(dirname "$fallback")
    mkdir -p "$fallback_dir" 2>/dev/null || true
    if mg_try_create_file "$fallback"; then
        MG_LOG_FILE=$fallback
        chmod 640 "$MG_LOG_FILE" 2>/dev/null || true
    fi
}

mg_load_config() {
    mg_set_default MG_CONFIG_FILE "/etc/marzguard.conf"
    if [[ -f "$MG_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$MG_CONFIG_FILE"
    fi

    mg_set_default MG_LOG_FILE "/var/log/marzguard.log"
    mg_set_default MG_LOG_LEVEL "INFO"
    mg_set_default MG_LOG_TO_STDOUT "1"
    mg_set_default MG_PROMETHEUS_OUTPUT "0"
    mg_set_default MG_PROMETHEUS_PATH ""
    mg_set_default MG_RUNTIME_DIR "/var/lib/marzguard"
    mg_set_default MG_STATE_DIR "/run/marzguard"
    mg_set_default MG_CONTAINER_FILTER_KEYWORDS "marzban"
    mg_set_default MG_APP_ROLE_KEYWORDS "marzban,app"
    mg_set_default MG_DB_ROLE_KEYWORDS "db,database,postgres,postgresql,mysql,mariadb"
    mg_set_default MG_SAMPLE_INTERVAL "0.5"
    mg_set_default MG_WINDOW_SIZE "5"
    mg_set_default MG_MIN_BREACHES "3"
    mg_set_default MG_CPU_LIMIT_PERCENT "110"
    mg_set_default MG_MEM_LIMIT_PERCENT "85"
    mg_set_default MG_AUTO_LIMIT_CPU "1"
    mg_set_default MG_CPU_LIMIT_CPUS "1.5"
    mg_set_default MG_AUTO_LIMIT_MEM "0"
    mg_set_default MG_MEM_LIMIT_BYTES ""
    mg_set_default MG_AUTO_RESTART "1"
    mg_set_default MG_AUTO_RESTART_DOCKER "0"
    mg_set_default MG_COOLDOWN_SECONDS "300"
    mg_set_default MG_RUNTIME_BINARY ""
    mg_set_default MG_ENABLE_HEALTH_CHECK "1"
    mg_set_default MG_ENABLE_RESTART_COUNT_CHECK "1"
    mg_set_default MG_ENABLE_DISK_CHECK "1"
    mg_set_default MG_ENABLE_DAEMON_CHECK "1"
    mg_set_default MG_ENABLE_NETWORK_CHECK "1"
    mg_set_default MG_NETWORK_CHECK_HOST "127.0.0.1"
    mg_set_default MG_NETWORK_CHECK_PORT "8000"
    mg_set_default MG_DETECTION_INTERVAL "10"
    mg_set_default MG_MOCK_MODE "0"
    mg_set_default MG_SELF_TEST_DURATION "5"
    mg_set_default MG_MAX_SAMPLE_LOG "1"
    mg_set_default MG_RUNTIME_USER "root"
    mg_set_default MG_DISK_THRESHOLD_ROOT "90"
    mg_set_default MG_DISK_THRESHOLD_DOCKER "90"
    mg_set_default MG_DOCKER_DATA_ROOT "/var/lib/docker"

    mg_init_paths
}

mg_now() {
    date +%s
}

mg_log_level_value() {
    local level=${1:-INFO}
    case ${level^^} in
        DEBUG) echo 0 ;;
        INFO) echo 1 ;;
        WARN) echo 2 ;;
        ERROR) echo 3 ;;
        *) echo 1 ;;
    esac
}

mg_log() {
    local level=${1:-INFO}
    shift || true
    local message="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local want=0
    local msg_level current_level
    msg_level=$(mg_log_level_value "$level")
    current_level=$(mg_log_level_value "$MG_LOG_LEVEL")
    if (( msg_level >= current_level )); then
        want=1
    fi
    if (( want == 1 )); then
        echo "[$ts] ${level^^} $message" >>"$MG_LOG_FILE"
        if [[ ${MG_LOG_TO_STDOUT:-0} -eq 1 ]]; then
            echo "[$ts] ${level^^} $message"
        fi
    fi
}

mg_is_mock_mode() {
    if [[ ${MG_MOCK_MODE:-0} -eq 1 ]]; then
        return 0
    fi
    if [[ ${MARZGUARD_MOCK:-0} -eq 1 ]]; then
        return 0
    fi
    return 1
}

mg_resolve_runtime() {
    if mg_is_mock_mode; then
        echo "mock"
        return 0
    fi
    if [[ -n ${MG_RUNTIME_BINARY:-} ]]; then
        echo "$MG_RUNTIME_BINARY"
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        echo "docker"
        return 0
    fi
    if command -v podman >/dev/null 2>&1; then
        echo "podman"
        return 0
    fi
    echo ""
    return 1
}

mg_csv_contains() {
    local haystack=$1
    local needle=$2
    if [[ -z $haystack ]]; then
        return 1
    fi
    local token
    IFS=',' read -r -a tokens <<<"$haystack"
    for token in "${tokens[@]}"; do
        token=${token// /}
        if [[ -z $token ]]; then
            continue
        fi
        if [[ ${needle,,} == *"${token,,}"* ]]; then
            return 0
        fi
    done
    return 1
}

mg_detect_containers() {
    local runtime
    runtime=$(mg_resolve_runtime || true)
    local now
    now=$(mg_now)
    : >"$MG_STATE_DIR/detected"
    if [[ $runtime == "mock" ]]; then
        cat <<EOF_mock >>"$MG_STATE_DIR/detected"
mock-app|mock-app|app|$now
mock-db|mock-db|db|$now
EOF_mock
        return 0
    fi
    if [[ -z $runtime ]]; then
        mg_log ERROR "No container runtime available for detection"
        return 1
    fi
    local format='{{.ID}}|{{.Names}}|{{.Image}}|{{.Labels}}'
    while IFS='|' read -r cid cname cimage clabels; do
        if [[ -z $cid ]]; then
            continue
        fi
        local blob
        blob="${cid,,} ${cname,,} ${cimage,,} ${clabels,,}"
        if ! mg_csv_contains "$MG_CONTAINER_FILTER_KEYWORDS" "$blob"; then
            continue
        fi
        local role="app"
        if mg_csv_contains "$MG_DB_ROLE_KEYWORDS" "$blob"; then
            role="db"
        elif mg_csv_contains "$MG_APP_ROLE_KEYWORDS" "$blob"; then
            role="app"
        fi
        printf '%s|%s|%s|%s\n' "$cid" "$cname" "$role" "$now" >>"$MG_STATE_DIR/detected"
    done < <("$runtime" ps --filter status=running --format "$format")
}

mg_get_detected() {
    if [[ ! -f "$MG_STATE_DIR/detected" ]]; then
        return 1
    fi
    cat "$MG_STATE_DIR/detected"
}

mg_mock_stat() {
    local cid=$1 role=$2
    local base
    base=$((${#cid} * 7 + ${#role} * 13 + $(mg_now)))
    local cpu=$(( base % 150 ))
    local mem=$(( (base / 3) % 95 ))
    printf '%s|%s|%s\n' "$cid" "$cpu" "$mem"
}

mg_collect_stats() {
    local runtime
    runtime=$(mg_resolve_runtime || true)
    if [[ $runtime == "mock" ]]; then
        while IFS='|' read -r cid _ role _; do
            mg_mock_stat "$cid" "$role"
        done <"$MG_STATE_DIR/detected"
        return 0
    fi
    if [[ -z $runtime ]]; then
        return 1
    fi
    local format='{{.ID}}|{{.CPUPerc}}|{{.MemPerc}}'
    "$runtime" stats --no-stream --format "$format"
}

mg_trim_window() {
    local data=$1
    local max=$2
    read -r -a arr <<<"$data"
    local count=${#arr[@]}
    local start=0
    if (( count > max )); then
        start=$((count - max))
    fi
    if (( count == 0 )); then
        echo ""
        return 0
    fi
    arr=("${arr[@]:${start}}")
    echo "${arr[*]}"
}

mg_update_windows() {
    local cid=$1 cpu=$2 mem=$3
    local cpu_data="${MG_CPU_WINDOWS[$cid]:-}"
    local mem_data="${MG_MEM_WINDOWS[$cid]:-}"
    if [[ -n $cpu_data ]]; then
        cpu_data="$cpu_data $cpu"
    else
        cpu_data="$cpu"
    fi
    if [[ -n $mem_data ]]; then
        mem_data="$mem_data $mem"
    else
        mem_data="$mem"
    fi
    MG_CPU_WINDOWS[$cid]=$(mg_trim_window "$cpu_data" "$MG_WINDOW_SIZE")
    MG_MEM_WINDOWS[$cid]=$(mg_trim_window "$mem_data" "$MG_WINDOW_SIZE")
}

mg_count_breaches() {
    local data=$1
    local threshold=$2
    local count=0
    local value
    for value in $data; do
        if awk "BEGIN{exit !($value > $threshold)}"; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

mg_within_cooldown() {
    local cid=$1
    local now
    now=$(mg_now)
    local last=${MG_LAST_ACTION_TS[$cid]:-0}
    if (( now - last < MG_COOLDOWN_SECONDS )); then
        return 0
    fi
    return 1
}

mg_record_action() {
    local cid=$1 role=$2 action=$3 detail=$4
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    MG_LAST_ACTION_TS[$cid]=$(mg_now)
    MG_LAST_ACTION_DESC[$cid]="$action : $detail"
    mkdir -p "$MG_RUNTIME_DIR"
    printf '%s|%s|%s|%s|%s\n' "$ts" "$cid" "$role" "$action" "$detail" >>"$MG_RUNTIME_DIR/last-actions.log"
}

mg_apply_cpu_limit() {
    local cid=$1 runtime=$2 value=${3:-$MG_CPU_LIMIT_CPUS}
    if [[ ${MG_AUTO_LIMIT_CPU:-0} -ne 1 ]]; then
        return 1
    fi
    if [[ -z $value ]]; then
        return 1
    fi
    if [[ $runtime == "mock" ]]; then
        mg_log INFO "Mock apply cpu limit $value on $cid"
        return 0
    fi
    if "$runtime" update --cpus "$value" "$cid"; then
        mg_log INFO "Applied CPU limit $value to $cid"
        return 0
    fi
    mg_log ERROR "Failed to apply CPU limit to $cid"
    return 1
}

mg_apply_mem_limit() {
    local cid=$1 runtime=$2 value=${3:-$MG_MEM_LIMIT_BYTES}
    if [[ ${MG_AUTO_LIMIT_MEM:-0} -ne 1 ]]; then
        return 1
    fi
    if [[ -z $value ]]; then
        return 1
    fi
    if [[ $runtime == "mock" ]]; then
        mg_log INFO "Mock apply memory limit $value on $cid"
        return 0
    fi
    if "$runtime" update --memory "$value" "$cid"; then
        mg_log INFO "Applied memory limit $value to $cid"
        return 0
    fi
    mg_log ERROR "Failed to apply memory limit to $cid"
    return 1
}

mg_restart_container() {
    local cid=$1 runtime=$2 role=$3
    if [[ ${MG_AUTO_RESTART:-0} -ne 1 ]]; then
        return 1
    fi
    if [[ $runtime == "mock" ]]; then
        mg_log WARN "Mock restart container $cid ($role)"
        return 0
    fi
    if "$runtime" restart "$cid"; then
        mg_log WARN "Restarted container $cid ($role)"
        return 0
    fi
    mg_log ERROR "Failed to restart container $cid"
    return 1
}

mg_restart_docker_daemon() {
    if [[ ${MG_AUTO_RESTART_DOCKER:-0} -ne 1 ]]; then
        return 1
    fi
    local runtime
    runtime=$(mg_resolve_runtime || true)
    if [[ $runtime == "mock" ]]; then
        mg_log WARN "Mock restart of runtime daemon"
        return 0
    fi
    local service="docker"
    if [[ $runtime == "podman" ]]; then
        service="podman"
    fi
    if systemctl restart "$service"; then
        mg_log WARN "Restarted $service daemon"
        return 0
    fi
    mg_log ERROR "Failed to restart $service daemon"
    return 1
}

mg_handle_breach() {
    local cid=$1 role=$2 cpu_breach=$3 mem_breach=$4 runtime=$5
    if mg_within_cooldown "$cid"; then
        mg_log DEBUG "Cooldown active for $cid"
        return 0
    fi
    local actions=""
    if (( cpu_breach )); then
        if mg_apply_cpu_limit "$cid" "$runtime"; then
            actions+="cpu-limit "
        fi
    fi
    if (( mem_breach )); then
        if mg_apply_mem_limit "$cid" "$runtime"; then
            actions+="mem-limit "
        fi
    fi
    if [[ -z $actions ]]; then
        if mg_restart_container "$cid" "$runtime" "$role"; then
            actions="restart"
        fi
    fi
    if [[ -z $actions ]] && [[ ${MG_AUTO_RESTART_DOCKER:-0} -eq 1 ]]; then
        if mg_restart_docker_daemon; then
            actions="runtime-restart"
        fi
    fi
    if [[ -n $actions ]]; then
        mg_record_action "$cid" "$role" "BREACH" "$actions"
    fi
}

mg_health_status() {
    local cid=$1 runtime=$2
    if [[ $runtime == "mock" ]]; then
        echo "healthy"
        return 0
    fi
    "$runtime" inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown"
}

mg_restart_count() {
    local cid=$1 runtime=$2
    if [[ $runtime == "mock" ]]; then
        echo 0
        return 0
    fi
    "$runtime" inspect --format '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0
}

mg_oom_killed() {
    local cid=$1 runtime=$2
    if [[ $runtime == "mock" ]]; then
        echo "false"
        return 0
    fi
    "$runtime" inspect --format '{{.State.OOMKilled}}' "$cid" 2>/dev/null || echo "false"
}

mg_check_optional_signals() {
    local cid=$1 role=$2 runtime=$3
    if [[ ${MG_ENABLE_HEALTH_CHECK:-1} -eq 1 ]]; then
        local health
        health=$(mg_health_status "$cid" "$runtime")
        if [[ $health != "healthy" && $health != "starting" ]]; then
            mg_log WARN "Container $cid ($role) health status $health"
        fi
    fi
    if [[ ${MG_ENABLE_RESTART_COUNT_CHECK:-1} -eq 1 ]]; then
        local count
        count=$(mg_restart_count "$cid" "$runtime")
        local prev=${MG_RESTART_COUNT_CACHE[$cid]:-0}
        if (( count > prev )); then
            mg_log WARN "Container $cid restart count increased to $count"
        fi
        MG_RESTART_COUNT_CACHE[$cid]=$count
    fi
    local oom
    oom=$(mg_oom_killed "$cid" "$runtime")
    if [[ $oom == "true" ]]; then
        mg_log WARN "Container $cid reported OOMKilled"
    fi
}

mg_check_disk_usage() {
    if [[ ${MG_ENABLE_DISK_CHECK:-1} -ne 1 ]]; then
        return 0
    fi
    local usage_root usage_docker
    usage_root=$(df -P / | awk 'NR==2 {print $5}' | tr -d '%')
    if awk "BEGIN{exit !($usage_root > $MG_DISK_THRESHOLD_ROOT)}"; then
        mg_log WARN "Root filesystem usage ${usage_root}% exceeds threshold ${MG_DISK_THRESHOLD_ROOT}%"
    fi
    local docker_path=${MG_DOCKER_DATA_ROOT:-/var/lib/docker}
    if [[ -d $docker_path ]]; then
        usage_docker=$(df -P "$docker_path" | awk 'NR==2 {print $5}' | tr -d '%')
        if awk "BEGIN{exit !($usage_docker > $MG_DISK_THRESHOLD_DOCKER)}"; then
            mg_log WARN "Docker data usage ${usage_docker}% exceeds threshold ${MG_DISK_THRESHOLD_DOCKER}%"
        fi
    fi
}

mg_check_network() {
    if [[ ${MG_ENABLE_NETWORK_CHECK:-1} -ne 1 ]]; then
        return 0
    fi
    local host=${MG_NETWORK_CHECK_HOST:-127.0.0.1}
    local port=${MG_NETWORK_CHECK_PORT:-8000}
    local timeout_cmd
    if command -v timeout >/dev/null 2>&1; then
        timeout_cmd=(timeout 5)
    else
        timeout_cmd=()
    fi
    if ! "${timeout_cmd[@]}" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        if command -v nc >/dev/null 2>&1; then
            if ! nc -z "$host" "$port" >/dev/null 2>&1; then
                mg_log WARN "Network endpoint $host:$port unreachable"
            fi
        else
            mg_log WARN "Network endpoint $host:$port unreachable"
        fi
    fi
}

mg_collect_stats_map() {
    MG_CPU_CURRENT=()
    MG_MEM_CURRENT=()
    local line cid cpu mem
    while IFS='|' read -r cid cpu mem; do
        if [[ -z $cid ]]; then
            continue
        fi
        cpu=${cpu%%%}
        mem=${mem%%%}
        MG_CPU_CURRENT[$cid]=$cpu
        MG_MEM_CURRENT[$cid]=$mem
    done < <(mg_collect_stats || true)
}

mg_monitor_iteration() {
    local runtime
    runtime=$(mg_resolve_runtime || true)
    if [[ -z $runtime ]]; then
        mg_log ERROR "Monitor cannot proceed: runtime unavailable"
        return 1
    fi

    if [[ ! -f "$MG_STATE_DIR/detected" ]]; then
        mg_detect_containers || true
    fi

    mg_collect_stats_map

    local line cid cname role ts
    while IFS='|' read -r cid cname role ts; do
        if [[ -z $cid ]]; then
            continue
        fi
        local cpu="${MG_CPU_CURRENT[$cid]:-0}"
        local mem="${MG_MEM_CURRENT[$cid]:-0}"
        mg_update_windows "$cid" "$cpu" "$mem"
        mg_check_optional_signals "$cid" "$role" "$runtime"
        local cpu_data="${MG_CPU_WINDOWS[$cid]:-}"
        local mem_data="${MG_MEM_WINDOWS[$cid]:-}"
        local cpu_breaches mem_breaches
        cpu_breaches=$(mg_count_breaches "$cpu_data" "$MG_CPU_LIMIT_PERCENT")
        mem_breaches=$(mg_count_breaches "$mem_data" "$MG_MEM_LIMIT_PERCENT")
        local cpu_hit=0 mem_hit=0
        if (( cpu_breaches >= MG_MIN_BREACHES )); then
            cpu_hit=1
        fi
        if (( mem_breaches >= MG_MIN_BREACHES )); then
            mem_hit=1
        fi
        if (( cpu_hit == 1 || mem_hit == 1 )); then
            mg_log WARN "Threshold breach for $cid cpu_breaches=$cpu_breaches mem_breaches=$mem_breaches"
            mg_handle_breach "$cid" "$role" "$cpu_hit" "$mem_hit" "$runtime"
        else
            if [[ ${MG_MAX_SAMPLE_LOG:-0} -eq 1 ]]; then
                mg_log DEBUG "Sample $cid cpu=$cpu mem=$mem"
            fi
        fi
    done <"$MG_STATE_DIR/detected"

    mg_check_disk_usage
    mg_check_network
}

mg_monitor_loop() {
    mg_load_config
    mg_log INFO "MarzGuard monitor starting version $MG_VERSION"
    local last_detection=0
    while true; do
        local now
        now=$(mg_now)
        if (( now - last_detection >= MG_DETECTION_INTERVAL )); then
            mg_detect_containers || true
            last_detection=$now
        fi
        mg_monitor_iteration || true
        sleep "$MG_SAMPLE_INTERVAL"
    done
}

mg_self_test() {
    mg_load_config
    MG_MOCK_MODE=1
    mg_detect_containers
    local start
    start=$(mg_now)
    local duration=${MG_SELF_TEST_DURATION:-5}
    local end=$((start + duration))
    while (( $(mg_now) < end )); do
        mg_monitor_iteration || true
        sleep "$MG_SAMPLE_INTERVAL"
    done
    mg_log INFO "Self-test completed successfully"
}

mg_recent_actions() {
    local lines=${1:-10}
    if [[ -f "$MG_RUNTIME_DIR/last-actions.log" ]]; then
        tail -n "$lines" "$MG_RUNTIME_DIR/last-actions.log"
    fi
}

mg_containers_by_role() {
    local target=$1
    if [[ ! -f "$MG_STATE_DIR/detected" ]]; then
        mg_detect_containers || true
    fi
    while IFS='|' read -r cid cname role ts; do
        if [[ -z $cid ]]; then
            continue
        fi
        if [[ $target == "both" || $target == "$role" ]]; then
            echo "$cid|$cname|$role"
        fi
    done <"$MG_STATE_DIR/detected"
}

mg_manual_limit_cpu() {
    local value=$1 roles=${2:-both}
    local runtime
    runtime=$(mg_resolve_runtime || true)
    if [[ -z $runtime ]]; then
        mg_log ERROR "Cannot apply CPU limit: runtime unavailable"
        return 1
    fi
    local cid cname role rc=0
    while IFS='|' read -r cid cname role; do
        if [[ -z $cid ]]; then
            continue
        fi
        if mg_apply_cpu_limit "$cid" "$runtime" "$value"; then
            mg_record_action "$cid" "$role" "MANUAL" "cpu-limit $value"
        else
            rc=1
        fi
    done < <(mg_containers_by_role "$roles")
    return $rc
}

mg_manual_limit_mem() {
    local value=$1 roles=${2:-both}
    local runtime
    runtime=$(mg_resolve_runtime || true)
    if [[ -z $runtime ]]; then
        mg_log ERROR "Cannot apply memory limit: runtime unavailable"
        return 1
    fi
    local line cid cname role rc=0
    while IFS='|' read -r cid cname role; do
        if [[ -z $cid ]]; then
            continue
        fi
        if mg_apply_mem_limit "$cid" "$runtime" "$value"; then
            mg_record_action "$cid" "$role" "MANUAL" "mem-limit $value"
        else
            rc=1
        fi
    done < <(mg_containers_by_role "$roles")
    return $rc
}

mg_manual_restart() {
    local roles=${1:-both}
    local runtime
    runtime=$(mg_resolve_runtime || true)
    if [[ -z $runtime ]]; then
        mg_log ERROR "Cannot restart: runtime unavailable"
        return 1
    fi
    local rc=0 cid cname role
    while IFS='|' read -r cid cname role; do
        if [[ -z $cid ]]; then
            continue
        fi
        if [[ $runtime == "mock" ]]; then
            mg_log INFO "Mock manual restart of $cid ($role)"
            mg_record_action "$cid" "$role" "MANUAL" "restart"
            continue
        fi
        if "$runtime" restart "$cid"; then
            mg_log WARN "Manually restarted $cid ($role)"
            mg_record_action "$cid" "$role" "MANUAL" "restart"
        else
            mg_log ERROR "Failed manual restart for $cid"
            rc=1
        fi
    done < <(mg_containers_by_role "$roles")
    return $rc
}

mg_manual_runtime_restart() {
    local runtime
    runtime=$(mg_resolve_runtime || true)
    if [[ -z $runtime ]]; then
        mg_log ERROR "Runtime not available"
        return 1
    fi
    if [[ $runtime == "mock" ]]; then
        mg_log INFO "Mock runtime restart"
        return 0
    fi
    local service="docker"
    if [[ $runtime == "podman" ]]; then
        service="podman"
    fi
    if systemctl restart "$service"; then
        mg_log WARN "Manually restarted $service"
        return 0
    fi
    mg_log ERROR "Failed to restart $service"
    return 1
}

mg_reload_config() {
    # Intended to be called after SIGHUP or via CLI
    mg_log INFO "Reloading configuration"
    MG_CPU_WINDOWS=()
    MG_MEM_WINDOWS=()
    MG_LAST_ACTION_TS=()
    # shellcheck disable=SC2034
    MG_LAST_ACTION_DESC=()
    mg_load_config
    mg_detect_containers || true
}


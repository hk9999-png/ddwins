#!/usr/bin/env bash

set -Eeuo pipefail

COMPOSE=()
DOCKER_SNAPSHOT=""
HOST_PORTS=""
PORT_CONFLICT=""
BASE_DIR=""
INSTANCE_DIR=""
CONTAINER_NAME=""

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

handle_error() {
    local exit_code=$1 line_number=$2
    trap - ERR
    printf '\n部署未完成（第 %s 行，退出码 %s），不会删除旧容器。\n' "$line_number" "$exit_code" >&2
    if [[ -n "$INSTANCE_DIR" && -f "$INSTANCE_DIR/docker-compose.yml" ]]; then
        printf '本次配置保留在：%s/docker-compose.yml\n' "$INSTANCE_DIR" >&2
    fi
    exit "$exit_code"
}

check_prerequisites() {
    [[ $(uname -s) == Linux ]] || die '请把脚本上传到 Linux Docker 服务器后运行，不是在 Windows 桌面运行。'
    (( BASH_VERSINFO[0] >= 4 )) || die '需要 Bash 4 或更高版本，请使用 bash 运行本脚本。'
    local required_command docker_endpoint
    for required_command in docker ss flock awk df od tr; do
        command -v "$required_command" >/dev/null 2>&1 || die "缺少命令：$required_command。ss 由 iproute2/iproute 提供，flock 由 util-linux 提供。"
    done
    docker info >/dev/null || die '无法访问 Docker，请先启动 Docker，并使用 root 或有 Docker 权限的用户运行。'
    if [[ -n ${DOCKER_CONTEXT:-} ]]; then
        docker_endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}') || die '无法检查 Docker context。'
    elif [[ -n ${DOCKER_HOST:-} ]]; then
        docker_endpoint=$DOCKER_HOST
    else
        docker_endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}') || die '无法检查 Docker context。'
    fi
    [[ "$docker_endpoint" == unix://* ]] || die '请在 Docker 所在的 Linux 主机运行；远程 Docker context 无法准确检查本机端口和磁盘。'
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        die '请先安装 Docker Compose v2（推荐）或 docker-compose 1.29+。'
    fi
    [[ -c /dev/kvm ]] || die '没有 /dev/kvm，请先启用 KVM/嵌套虚拟化。'
    [[ -c /dev/net/tun ]] || die '没有 /dev/net/tun，请先在服务器执行 sudo modprobe tun，并确认 TUN 可用。'
}

initialize_input() {
    if [[ -t 0 ]]; then
        exec 3<&0
    elif { exec 3</dev/tty; } 2>/dev/null; then
        :
    else
        exec 3<&0
    fi
}

acquire_deployment_lock() {
    local daemon_id lock_path
    daemon_id=$(docker info --format '{{.ID}}') || die '无法确认 Docker daemon，未继续创建。'
    [[ "$daemon_id" =~ ^[a-zA-Z0-9:_-]{1,128}$ ]] || die 'Docker daemon ID 无效，无法安全建立部署锁。'
    lock_path="/tmp/ddwins-deploy-${daemon_id}.lock"
    if [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
        if ! (umask 022; set -o noclobber; : > "$lock_path") 2>/dev/null; then
            [[ -f "$lock_path" && ! -L "$lock_path" ]] || die "无法创建部署锁：$lock_path"
        fi
    fi
    [[ -f "$lock_path" && ! -L "$lock_path" && -r "$lock_path" ]] || die "部署锁不是可读的普通文件，请由管理员核查：$lock_path"
    exec 9<"$lock_path"
    flock -n 9 || die '此 Docker 主机已有 Windows 创建任务在运行，请等待它完成。'
}

read_value() {
    local target_variable=$1 prompt_text=$2 default_value=${3:-} entered_value
    printf '%s' "$prompt_text" >&2
    IFS= read -r entered_value <&3 || die '输入已中断，未继续创建容器。'
    printf -v "$target_variable" '%s' "${entered_value:-$default_value}"
}

refresh_port_usage() {
    local container_ids socket_snapshot
    local -a inspect_ids=()
    container_ids=$(docker ps -aq) || die '无法读取现有容器，不能安全检查端口和名称。'
    DOCKER_SNAPSHOT=""
    if [[ -n "$container_ids" ]]; then
        mapfile -t inspect_ids <<< "$container_ids"
        DOCKER_SNAPSHOT=$(docker inspect --format '{{printf "NAME|%s\n" .Name}}{{if .Config.Labels}}{{with index .Config.Labels "com.docker.compose.project"}}{{printf "PROJECT|%s\n" .}}{{end}}{{end}}{{range .HostConfig.PortBindings}}{{range .}}{{printf "PORT|%s\n" .HostPort}}{{end}}{{end}}{{range .NetworkSettings.Ports}}{{range .}}{{printf "PORT|%s\n" .HostPort}}{{end}}{{end}}' "${inspect_ids[@]}") || die '无法读取容器端口配置，请重试。'
    fi
    socket_snapshot=$(ss -H -antu) || die '无法检查宿主机 TCP/UDP 端口，未继续部署。'
    HOST_PORTS=$(awk '{ endpoint = $5; sub(/^.*:/, "", endpoint); if (endpoint ~ /^[0-9]+$/) print endpoint }' <<< "$socket_snapshot")
}

port_in_use() {
    local requested_port=$1 record_type record_value record_owner container_owner="" host_port
    PORT_CONFLICT=""
    while IFS='|' read -r record_type record_value record_owner; do
        case "$record_type" in
            NAME) container_owner=${record_value#/} ;;
            PORT)
                if [[ "$record_value" == "$requested_port" ]]; then
                    PORT_CONFLICT="Docker 容器 ${record_owner:-$container_owner} 已使用或预留该端口（包括停止的容器）"
                    return 0
                fi
                ;;
        esac
    done <<< "$DOCKER_SNAPSHOT"
    while IFS= read -r host_port; do
        if [[ "$host_port" == "$requested_port" ]]; then
            PORT_CONFLICT='宿主机已有 TCP/UDP 服务占用该端口'
            return 0
        fi
    done <<< "$HOST_PORTS"
    return 1
}

prompt_port() {
    local target_variable=$1 default_port=$2 port_label=$3 other_port=${4:-}
    local entered_port normalized_port
    while true; do
        read_value entered_port "$port_label [默认 $default_port]: " "$default_port"
        if [[ ! "$entered_port" =~ ^[0-9]{1,5}$ ]]; then
            printf '请输入 1～65535 之间的整数端口，不能留空以外的非数字内容。\n' >&2
            continue
        fi
        normalized_port=$((10#$entered_port))
        if (( normalized_port < 1 || normalized_port > 65535 )); then
            printf '端口必须在 1～65535 之间，请重新输入。\n' >&2
            continue
        fi
        if [[ -n "$other_port" && "$normalized_port" == "$other_port" ]]; then
            printf 'Web 和 RDP 不能使用同一个端口，请重新输入。\n' >&2
            continue
        fi
        refresh_port_usage
        if port_in_use "$normalized_port"; then
            printf '端口 %s 不可用：%s。请重新输入。\n' "$normalized_port" "$PORT_CONFLICT" >&2
            continue
        fi
        printf -v "$target_variable" '%s' "$normalized_port"
        return 0
    done
}

recheck_selected_ports() {
    while true; do
        refresh_port_usage
        if port_in_use "$WEB_PORT"; then
            printf 'Web 端口 %s 在配置期间变为不可用：%s。\n' "$WEB_PORT" "$PORT_CONFLICT" >&2
            prompt_port WEB_PORT "$WEB_PORT" 'Web 管理端口' "$RDP_PORT"
            continue
        fi
        if port_in_use "$RDP_PORT"; then
            printf 'RDP 端口 %s 在配置期间变为不可用：%s。\n' "$RDP_PORT" "$PORT_CONFLICT" >&2
            prompt_port RDP_PORT "$RDP_PORT" 'RDP 远程桌面端口' "$WEB_PORT"
            continue
        fi
        return 0
    done
}

choose_instance_name() {
    local highest_index=21 record_type record_value record_owner instance_path existing_name suffix instance_index
    local -a existing_names=()
    while IFS='|' read -r record_type record_value record_owner; do
        if [[ "$record_type" == NAME || "$record_type" == PROJECT ]]; then
            existing_names+=("${record_value#/}")
        fi
    done <<< "$DOCKER_SNAPSHOT"
    for instance_path in "$BASE_DIR"/windows*; do
        if [[ -e "$instance_path" || -L "$instance_path" ]]; then
            existing_names+=("${instance_path##*/}")
        fi
    done
    for existing_name in "${existing_names[@]}"; do
        if [[ "$existing_name" =~ ^windows([0-9]+)$ ]]; then
            suffix=${BASH_REMATCH[1]}
            (( ${#suffix} <= 9 )) || die "已有实例序号过长，无法安全递增：$existing_name"
            instance_index=$((10#$suffix))
            if (( instance_index > highest_index )); then
                highest_index=$instance_index
            fi
        fi
    done
    CONTAINER_NAME="windows$((highest_index + 1))"
    INSTANCE_DIR="$BASE_DIR/$CONTAINER_NAME"
}

prompt_size() {
    local target_variable=$1 default_size=$2 size_label=$3 entered_size
    while true; do
        read_value entered_size "$size_label [默认 $default_size，不带单位按 G]: " "$default_size"
        entered_size=${entered_size^^}
        if [[ "$entered_size" =~ ^[1-9][0-9]{0,5}$ ]]; then
            entered_size="${entered_size}G"
        fi
        if [[ "$entered_size" =~ ^[1-9][0-9]{0,5}[MGT]$ ]]; then
            printf -v "$target_variable" '%s' "$entered_size"
            return 0
        fi
        printf '请输入正整数，不带单位默认 G，例如 80、300；也支持 4096M、80G 或 1T。\n' >&2
    done
}

prompt_password() {
    local random_part
    WINDOWS_USERNAME="admin"
    while true; do
        printf 'Windows 管理员密码 [回车自动生成；自设至少12位，含大小写字母和数字]: ' >&2
        IFS= read -rs WINDOWS_PASSWORD <&3 || die '密码输入已中断。'
        printf '\n' >&2
        if [[ -z "$WINDOWS_PASSWORD" ]]; then
            random_part=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
            [[ "$random_part" =~ ^[0-9a-f]{24}$ ]] || die '无法生成安全密码。'
            WINDOWS_PASSWORD="Win@${random_part}A1"
            return 0
        fi
        if (( ${#WINDOWS_PASSWORD} >= 12 && ${#WINDOWS_PASSWORD} <= 127 )) &&
            [[ "$WINDOWS_PASSWORD" =~ [a-z] && "$WINDOWS_PASSWORD" =~ [A-Z] && "$WINDOWS_PASSWORD" =~ [0-9] && ! "$WINDOWS_PASSWORD" =~ [[:cntrl:]] ]]; then
            return 0
        fi
        printf '密码不符合要求：请使用 12～127 位，包含大小写字母和数字，不含控制字符。\n' >&2
    done
}

yaml_quote() {
    local escaped_value=$1
    escaped_value=${escaped_value//\$/\$\$}
    escaped_value=${escaped_value//\'/\'\'}
    printf "'%s'" "$escaped_value"
}

write_compose() {
    mkdir -p -- "$INSTANCE_DIR/storage"
    cat > "$INSTANCE_DIR/docker-compose.yml" <<EOF
services:
  windows:
    image: dockurr/windows
    container_name: $CONTAINER_NAME
    environment:
      VERSION: "2022"
      LANGUAGE: "English"
      CPU_CORES: "$MY_CPU"
      RAM_SIZE: "$MY_RAM"
      USERNAME: $(yaml_quote "$WINDOWS_USERNAME")
      PASSWORD: $(yaml_quote "$WINDOWS_PASSWORD")
      DISK_SIZE: "$MY_DISK"
    devices:
      - /dev/kvm:/dev/kvm
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - target: 8006
        published: "$WEB_PORT"
        protocol: tcp
      - target: 3389
        published: "$RDP_PORT"
        protocol: tcp
      - target: 3389
        published: "$RDP_PORT"
        protocol: udp
    volumes:
      - type: bind
        source: ./storage
        target: /storage
    restart: unless-stopped
    stop_grace_period: 2m
EOF
    chmod 600 -- "$INSTANCE_DIR/docker-compose.yml"
}

run_compose() {
    "${COMPOSE[@]}" --project-directory "$INSTANCE_DIR" -p "$CONTAINER_NAME" -f "$INSTANCE_DIR/docker-compose.yml" "$@"
}

assert_new_instance_absent() {
    local existing_container_id
    existing_container_id=$(docker ps -aq --filter "name=^/${CONTAINER_NAME}$") || die '启动前无法复核容器名称，未继续启动。'
    [[ -z "$existing_container_id" ]] || die "容器名 $CONTAINER_NAME 已被其他任务占用，未启动或重新创建它。请重新运行脚本。"
}

verify_port_mappings() {
    local running_state actual_bindings container_port host_port instance_owner
    local web_found=0 rdp_tcp_found=0 rdp_udp_found=0 expected_port
    instance_owner=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CONTAINER_NAME") || die '启动后无法确认新容器所属目录。'
    [[ "$instance_owner" == "$INSTANCE_DIR" ]] || die '实例名称被另一个创建任务占用，未重新创建它。请重新运行脚本以选择新的编号。'
    running_state=$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME") || die '启动后无法读取新容器状态。'
    [[ "$running_state" == true ]] || die "新容器没有正常运行，请查看 docker logs $CONTAINER_NAME。"
    actual_bindings=$(docker inspect --format '{{range $containerPort, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{printf "%s|%s\n" $containerPort .HostPort}}{{end}}{{end}}' "$CONTAINER_NAME") || die '启动后无法读取实际端口映射。'
    while IFS='|' read -r container_port host_port; do
        case "$container_port" in
            8006/tcp) expected_port=$WEB_PORT; web_found=1 ;;
            3389/tcp) expected_port=$RDP_PORT; rdp_tcp_found=1 ;;
            3389/udp) expected_port=$RDP_PORT; rdp_udp_found=1 ;;
            *) continue ;;
        esac
        [[ "$host_port" == "$expected_port" ]] || die "端口映射不一致：$container_port 实际映射到 $host_port，期望 $expected_port。请检查 $INSTANCE_DIR/docker-compose.yml。"
    done <<< "$actual_bindings"
    (( web_found && rdp_tcp_found && rdp_udp_found )) || die '新容器的 Web/RDP TCP/UDP 映射不完整，请检查 Docker 日志。'
}

main() {
    umask 077
    trap 'handle_error "$?" "$LINENO"' ERR
    check_prerequisites
    initialize_input
    acquire_deployment_lock
    BASE_DIR=${WINDOWS_BASE_DIR:-"$PWD/windows-instances"}
    mkdir -p -- "$BASE_DIR"
    BASE_DIR=$(cd -- "$BASE_DIR" && pwd -P)

    printf '%s\n' '--------------------------------' '创建新的 Windows Server 2022，不修改或删除已有实例。' '已有容器（含已停止容器）预留的端口和宿主机占用端口均不可重复。'
    prompt_port WEB_PORT 8001 'Web 管理端口'
    prompt_port RDP_PORT 3381 'RDP 远程桌面端口' "$WEB_PORT"

    while true; do
        read_value MY_CPU 'CPU 核心数 [默认 15]: ' 15
        if [[ "$MY_CPU" =~ ^[1-9][0-9]{0,3}$ ]]; then
            break
        fi
        printf 'CPU 核心数必须是 1～9999 之间的正整数。\n' >&2
    done
    prompt_size MY_RAM 110G 'RAM 内存大小'
    local free_space suggested_disk
    free_space=$(df -Pk "$BASE_DIR" | awk 'NR == 2 { printf "%.0f", int($4 / 1048576) }')
    [[ "$free_space" =~ ^[0-9]+$ ]] || die '无法获取存储目录剩余空间。'
    (( free_space >= 2 )) || die '存储目录所在磁盘剩余空间不足 2 GiB，请先清理空间或修改 WINDOWS_BASE_DIR。'
    suggested_disk=$((free_space * 9 / 10))
    if (( suggested_disk > 999 )); then suggested_disk=999; fi
    printf '存储分区剩余空间：%s GiB；默认预留约 10%%，虚拟硬盘建议上限 999G。\n' "$free_space"
    prompt_size MY_DISK "${suggested_disk}G" '硬盘大小'
    prompt_password

    recheck_selected_ports
    choose_instance_name
    mkdir -- "$INSTANCE_DIR" || die "不能新建实例目录：$INSTANCE_DIR；没有覆盖已有文件。"
    write_compose
    printf '\n新容器/Compose 项目：%s\n独立配置和数据目录：%s\n' "$CONTAINER_NAME" "$INSTANCE_DIR"
    run_compose config --quiet || die "Compose 配置校验失败，配置已保留：$INSTANCE_DIR/docker-compose.yml"
    assert_new_instance_absent
    if ! run_compose up -d --no-recreate; then
        die "容器启动失败，没有报告成功，也不会删除旧容器。本次配置保留在：$INSTANCE_DIR/docker-compose.yml"
    fi
    verify_port_mappings

    printf '\n%s\n' '--------------------------------' '容器已启动，实际端口映射已核对。Windows 安装仍需等待。'
    printf '容器名称：%s\nWeb 管理：http://服务器IP:%s\nRDP 远程桌面：服务器IP:%s（TCP/UDP）\n' "$CONTAINER_NAME" "$WEB_PORT" "$RDP_PORT"
    printf 'Windows 用户名：%s\nWindows 密码：%s\n' "$WINDOWS_USERNAME" "$WINDOWS_PASSWORD"
    printf '配置文件：%s/docker-compose.yml\n磁盘目录：%s/storage\n' "$INSTANCE_DIR" "$INSTANCE_DIR"
    printf '查看日志：docker logs -f %s\n' "$CONTAINER_NAME"
    printf '%s\n' '请妥善保存密码。请在防火墙/安全组按需放行端口，优先仅允许自己的 IP 或 VPN。' '再次运行本脚本会创建编号递增的新实例，不会复用现有虚拟硬盘。'
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi

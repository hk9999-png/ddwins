#!/bin/bash

# --- 1. 下载远程配置文件 ---
echo "正在获取远程配置..."
curl -s -O https://raw.githubusercontent.com/hk9999-png/ddwins/refs/heads/main/docker-compose.yml

if [ $? -ne 0 ]; then
    echo "下载失败，请检查网络连接。"
    exit 1
fi

# --- 2. 交互式输入配置 ---
echo "--------------------------------"
echo "请配置您的 Windows 容器参数（直接回车使用默认值）"

read -p "Web 管理端口 [默认 8001]: " WEB_PORT
export WEB_PORT=${WEB_PORT:-8001}

read -p "RDP 远程桌面端口 [默认 3381]: " RDP_PORT
export RDP_PORT=${RDP_PORT:-3381}

read -p "CPU 核心数 [默认 15]: " MY_CPU
export MY_CPU=${MY_CPU:-15}

read -p "RAM 内存大小 (例如 110G) [默认 110G]: " MY_RAM
export MY_RAM=${MY_RAM:-110G}

# --- 3. 硬盘空间自动检测逻辑 ---
# 获取当前目录所在分区的剩余空间 (GB)
FREE_SPACE=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')

echo "检测到磁盘剩余空间: ${FREE_SPACE}G"

if [ "$FREE_SPACE" -ge 1000 ]; then
    SUGGESTED_DISK="999G"
elif [ "$FREE_SPACE" -ge 500 ]; then
    SUGGESTED_DISK="500G"
else
    # 空间不足 500G 时，默认建议为剩余空间的 90%
    SUGGESTED_DISK="$((FREE_SPACE * 9 / 10))G"
fi

read -p "请输入硬盘大小 [建议 $SUGGESTED_DISK]: " MY_DISK
export MY_DISK=${MY_DISK:-$SUGGESTED_DISK}

# --- 4. 动态修改并启动 ---
# 使用 sed 将下载的文件中的硬编码值替换为环境变量占位符
# 这样可以让 docker-compose 读取我们 export 的变量
sed -i 's/CPU_CORES: ".*"/CPU_CORES: "${MY_CPU}"/g' docker-compose.yml
sed -i 's/RAM_SIZE: ".*"/RAM_SIZE: "${MY_RAM}"/g' docker-compose.yml
sed -i 's/DISK_SIZE: ".*"/DISK_SIZE: "${MY_DISK}"/g' docker-compose.yml
sed -i 's/- 8001:8006/- ${WEB_PORT}:8006/g' docker-compose.yml
# 替换 RDP 端口（注意处理 tcp/udp 两行）
sed -i 's/- 3381:3389/- ${RDP_PORT}:3389/g' docker-compose.yml

echo "--------------------------------"
echo "配置完成！即将启动..."
echo "访问地址: http://IP:${WEB_PORT}"
echo "远程桌面: IP:${RDP_PORT}"
echo "--------------------------------"

# 启动容器
docker-compose up -d

echo "任务已提交，容器正在后台初始化，请稍候。"

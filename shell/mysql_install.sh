#!/bin/bash
#
# MySQL自动化部署脚本
# 支持CentOS/RHEL/Rocky Linux 8+，自动处理依赖安装、用户创建、服务注册
# 
# 使用方法: bash mysql_install.sh
# 修改配置: 编辑脚本开头的配置参数部分
#
# Author: yinbao77
# Date: $(date +%F)
#

# +++++++ 变量定义 +++++++
INSTALL_DIR=/opt/mysql8
MYSQL_PORT=3306
MYSQL_PASSWD=123456
MYSQL_USER=mysql
# 动态下载信息
SQL_NAME='mysql-8.0.43-linux-glibc2.28-x86_64.tar.xz'
DOWNLOAD_URL="https://dev.mysql.com/get/Downloads/MySQL-8.0/${SQL_NAME}"

# +++++++ 函数定义 +++++++
error() {
    echo "[$(date '+%F-%T')] 错误：$1" >&2
    exit "${2:-1}"
}

info() {
    echo "[$(date '+%F-%T')] 信息：$1"
}

# 检查系统和端口
check_env() {
    # 检查root权限
    [[ $EUID -ne 0 ]] && error "需要root权限运行"

    # 检查端口占用
    if netstat -tuln 2>/dev/null | grep -q ":${MYSQL_PORT}" || ss -tuln 2>/dev/null | grep -q ":${MYSQL_PORT}"; then
        error "端口 ${MYSQL_PORT} 已被占用"
    fi

    # 检查磁盘空间
    local avail_gb=$(df -BG $(dirname ${INSTALL_DIR}) | awk 'NR==2{print $4}' | tr -d 'G')
    [[ ${avail_gb} -lt 5 ]] && error "空间不足, 至少需要5GB"

    info "环境检查通过"
}

# +++++++ 安装流程 +++++++
info "开始安装MySQL"

# 环境检查
check_env

# 安装依赖
info "安装依赖包"
if command -v dnf >/dev/null 2>&1; then
    dnf install -y libaio numactl-libs wget &>/dev/null || error "依赖安装失败"
elif command -v yum >/dev/null 2>&1; then
    yum install -y libaio numactl-libs wget &>/dev/null || error "依赖安装失败"
else
    error "不支持的包管理器"
fi

# 停止可能存在的服务
systemctl stop mysqld mariadb &>/dev/null || true

# 下载解压
info "准备MySQL安装包"
if [[ ! -f "${SQL_NAME}" ]]; then
    info "正在下载MySQL安装包"
    wget --quiet --show-progress ${DOWNLOAD_URL} || error "MySQL下载失败"
fi

info "解压MySQL安装包"
mkdir -p ${INSTALL_DIR}
tar -xf "${SQL_NAME}" -C "${INSTALL_DIR}" --strip-components=1 || error "MySQL解压失败"

# 卸载可能存在的MariaDB
info "卸载MariaDB"
rpm -qa | grep mariadb | xargs -r dnf remove -y &>/dev/null || true
[[ -f /etc/my.cnf ]] && rm -f /etc/my.cnf
[[ -d /var/log/mariadb ]] && rm -rf /var/log/mariadb

# 创建MySQL用户
info "创建MySQL用户"
if ! id ${MYSQL_USER} &>/dev/null; then
    useradd -r -s /sbin/nologin "${MYSQL_USER}"
fi

# 创建数据目录并设置权限
mkdir -p ${INSTALL_DIR}/data ${INSTALL_DIR}/logs ${INSTALL_DIR}/tmp
chown -R ${MYSQL_USER}:${MYSQL_USER} ${INSTALL_DIR}
chmod 750 ${INSTALL_DIR}/data

# 初始化数据库
info "初始化MySQL"
cd "${INSTALL_DIR}"
./bin/mysqld --initialize --user=${MYSQL_USER} --basedir=${INSTALL_DIR} --datadir=${INSTALL_DIR}/data > /tmp/mysqld.log 2>&1 || error "MySQL初始化失败"
temp_passwd=$(grep 'temporary password' /tmp/mysqld.log | awk '{print $NF}') # 提取临时密码
[[ -z "${temp_passwd}" ]] && error "无法获取临时密码"
info "临时密码：${temp_passwd}"

# 设置SSL
./bin/mysql_ssl_rsa_setup --datadir=${INSTALL_DIR}/data &> /dev/null

# 创建配置文件
info "创建MySQL配置文件"
cat > /etc/my.cnf <<EOF
[mysqld]
# 基础配置
user=${MYSQL_USER}
port=${MYSQL_PORT}
basedir=${INSTALL_DIR}
datadir=${INSTALL_DIR}/data
socket=/tmp/mysql.sock
pid-file=${INSTALL_DIR}/tmp/mysqld.pid

# 字符集配置
character_set_server=utf8mb4
collation_server=utf8mb4_unicode_ci

# 连接设置
max_connections=200
max_connect_errors=10
connect_timeout=10
wait_timeout=28800
interactive_timeout=28800

# 日志设置
log_error=${INSTALL_DIR}/logs/error.log
slow_query_log=1
slow_query_log_file=${INSTALL_DIR}/logs/slow_query.log
long_query_time=2

# 性能优化
innodb_buffer_pool_size=128M
innodb_log_file_size=48M

# 临时表设置
table_open_cache=256
thread_cache_size=8

[mysql]
default_character_set=utf8mb4

[client]
port=${MYSQL_PORT}
socket=/tmp/mysql.sock
default_character_set=utf8mb4
EOF

info "注册Systemd服务"
cat > /etc/systemd/system/mysqld.service <<EOF
[Unit]
Description=MySQL Server
Documentation=man:mysqld(8)
Documentation=http://dev.mysql.com/doc/refman/en/using-systemd.html
After=network.target
After=syslog.target
Wants=network-online.target

[Service]
User=${MYSQL_USER}
Group=${MYSQL_USER}
Type=notify
PermissionsStartOnly=true
ExecStartPre=/bin/mkdir -p ${INSTALL_DIR}/tmp
ExecStartPre=/bin/chown ${MYSQL_USER}:${MYSQL_USER} -R ${INSTALL_DIR}/tmp
ExecStart=${INSTALL_DIR}/bin/mysqld --defaults-file=/etc/my.cnf
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=${INSTALL_DIR}/bin/mysqladmin --defaults-file=/etc/my.cnf shutdown
TimeoutSec=600
Restart=on-failure
RestartPreventExitStatus=1
RestartSec=5

KillMode=process
KillSignal=SIGTERM
SendSIGKILL=no

PrivateTmp=false
LimitNOFILE=65535
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF

# 启动MySQL服务
info "启动MySQL服务"
systemctl daemon-reload
systemctl start mysqld
systemctl enable mysqld
# 等待服务启动
sleep 5
if ! systemctl is-active --quiet mysqld; then
    error "MySQL服务启动失败, 请检查日志文件: ${INSTALL_DIR}/logs/error.log"
fi

# 重置密码
info "重置root密码"
${INSTALL_DIR}/bin/mysqladmin -uroot password ${MYSQL_PASSWD} -p${temp_passwd} || error "修改root密码失败"

# 安全初始化
info "执行安全初始化"
${INSTALL_DIR}/bin/mysql -uroot -p${MYSQL_PASSWD} <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# 配置环境变量
info "配置环境变量"
echo "export PATH=\$PATH:${INSTALL_DIR}/bin" > /etc/profile.d/mysql.sh
chmod +x /etc/profile.d/mysql.sh

# 安装完成信息
echo "+++++++"
echo "MySQL is ok!!!"
echo "安装目录: ${INSTALL_DIR}"
echo "配置文件: /etc/my.cnf"
echo "数据目录: ${INSTALL_DIR}/data"
echo "日志目录: ${INSTALL_DIR}/logs"
echo "服务端口: ${MYSQL_PORT}"
echo "root密码: ${MYSQL_PASSWD}"
echo "+++++++"

# 清理临时文件
rm -f /tmp/mysqld.log
info "执行完毕,重启环境变量生效,注意防火墙是否开启${MYSQL_PORT}端口！！！"
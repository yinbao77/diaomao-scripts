#!/bin/bash
#
# Author: yinbao77
# Description: 监控磁盘使用情况，超过阈值时发送邮件告警并记录日志
#

# ================== 配置项 ==================
LOGFILE=/var/log/disk_usage.log         # 日志文件路径
THRESHOLD=10                            # 磁盘使用百分比阈值（例如：10 表示超过 10% 就告警）
FROM_EMAIL="your_from_email@example.com"  # 发件人邮箱（请替换为你自己的邮箱）
ALERT_EMAIL="your_alert_email@example.com"  # 收件人邮箱（请替换为你自己的邮箱）
# ==========================================

# 检查磁盘使用情况
check_disk_usage() {
  df -h | grep "^/dev/" | while read line; do
    PARTITION=$(echo $line | cut -d ' ' -f1)
    USAGE=$(echo $line | cut -d ' ' -f5 | tr -d '%')
    if [[ $USAGE -ge $THRESHOLD ]]; then
        alert_disk_usage "$PARTITION" "$USAGE"
    fi
  done
}

# 发送磁盘使用告警邮件
alert_disk_usage() {
  local PARTITION=$1
  local USAGE=$2

  echo "【$(date +"%F %T")】服务器 ${PARTITION} 空间超过阈值 ${USAGE}%" >> "$LOGFILE"

  # 邮件内容防中文乱码
  {
      echo "To: $ALERT_EMAIL"
      echo "From: $FROM_EMAIL"
      echo "Subject: $PARTITION 达到 ${USAGE}% ！！！"
      echo "MIME-Version: 1.0"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo
      echo "【$(date +"%F %T")】服务器 ${PARTITION} 空间超过阈值 ${USAGE}%，请运维处理！！！"
  } | sendmail -t
}

# 执行主函数
check_disk_usage
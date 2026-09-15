#!/usr/bin/env bash
# =============================================================================
# ① 传感器 + MAVROS：飞控串口授权 → mavros → 设置 200 Hz MAVLink 消息率 → 启动 Mid-360 驱动
#
# 用法：
#   ./start_sensor.sh
#   FCU_URL=/dev/ttyACM0:57600 ./start_sensor.sh     # 覆盖飞控串口与波特率
#
# ★ 首次在新机器上跑之前，请确认飞控串口的设备名与波特率：
#     ls /dev/ttyS* /dev/ttyACM* /dev/ttyUSB*
#     dmesg | grep -i tty | tail
#   端口名按你的接线（PX4 TELEM 口 → 机载计算机 UART/USB）定；
#   波特率要与此飞控参数 MAV_x_BAUD 一致（PX4 接伴飞电脑常用 921600）。
# =============================================================================
set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FCU_URL="${FCU_URL:-/dev/ttyS1:921600}"
FCU_DEV="${FCU_URL%%:*}"
LIDAR_LAUNCH="${LIDAR_LAUNCH:-livox_ros_driver2 msg_MID360.launch}"

roslaunch livox_ros_driver2 msg_MID360s.launch;

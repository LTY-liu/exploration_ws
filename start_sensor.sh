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

# shellcheck disable=SC1091
source /opt/ros/noetic/setup.bash
# shellcheck disable=SC1091
[ -f "$WS/devel/setup.bash" ] && source "$WS/devel/setup.bash"

echo "[sensor] 工作区   : $WS"
echo "[sensor] 飞控串口 : $FCU_URL"

if [ -e "$FCU_DEV" ]; then
  sudo chmod 777 "$FCU_DEV"
  echo "[sensor] 已放开 $FCU_DEV 权限（推荐改用 sudo usermod -aG dialout \$USER，之后就不需要这步）"
else
  echo "[sensor] ⚠ 找不到 $FCU_DEV —— 请检查接线与设备名，或改用 FCU_URL=... ./start_sensor.sh"
fi

roslaunch px4ctrl mavros_px4.launch fcu_url:="$FCU_URL" &
sleep 3

# 把 MAVLink HIGHRES_IMU(id 105) 与 ATTITUDE_QUATERNION(id 31) 的推送间隔设为
# 5000us = 200 Hz，保证 px4ctrl 拿到高频 IMU / 姿态（MAV_CMD_SET_MESSAGE_INTERVAL=511）
rosrun mavros mavcmd long 511 105 5000 0 0 0 0 0 &
sleep 1
rosrun mavros mavcmd long 511 31 5000 0 0 0 0 0 &
sleep 1

# Mid-360 驱动：xfer_format=1 → livox_ros_driver2/CustomMsg，publish_freq=10Hz
# shellcheck disable=SC2086
exec roslaunch $LIDAR_LAUNCH

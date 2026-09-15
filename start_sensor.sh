#!/usr/bin/env bash
# =============================================================================
# ① 传感器 + MAVROS：飞控串口授权 → mavros → 设置 200 Hz MAVLink 消息率 → 启动 Livox 驱动
#
# 用法：
#   ./start_sensor.sh
#   FCU_URL=/dev/ttyTHS1:921600 ./start_sensor.sh    # 覆盖飞控串口与波特率
#   LIDAR_LAUNCH="livox_ros_driver2 msg_MID360.launch" ./start_sensor.sh   # 覆盖雷达型号
#
# ★★★ 换机器必改：飞控串口 ★★★
#   下面 FCU_URL 的默认值 /dev/ttyS1:921600 **只适用于 Orange Pi / 树莓派这类板子**。
#   如果你用的是 Jetson Orin / Xavier / Nano，或者其它板子，请改成你板子上的设备口：
#
#       Jetson 系列        /dev/ttyTHS1     （也可能是 /dev/ttyTHS0）
#       PX4 USB 口直连     /dev/ttyACM0
#       MAVLink over UDP   udp://:14540@127.0.0.1:14557
#
#   波特率必须与该飞控参数 MAV_x_BAUD 一致（接伴飞电脑的 TELEM 口通常 921600）。
#   不确定用哪个？见 README「四、硬件相关配置 → 1. 飞控串口」里的 python 探测脚本。
#
#   判断设备口对不对的最快方法：
#     · 报 "No such file or directory"  → 设备名写错了
#     · 报 "Input/output error"         → 节点存在但没有可用 UART，换设备口
#       （注意：这**不是**没接飞控 —— UART 的 open 并不需要对面有设备）
# =============================================================================
set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FCU_URL="${FCU_URL:-/dev/ttyS1:921600}"
FCU_DEV="${FCU_URL%%:*}"
# ★ 雷达型号在这里切换：普通 Mid-360 用 msg_MID360.launch，
#   Mid-360S 用 msg_MID360s.launch（对应 config/MID360s_config.json，雷达 IP 是 .107）
LIDAR_LAUNCH="${LIDAR_LAUNCH:-livox_ros_driver2 msg_MID360s.launch}"

# shellcheck disable=SC1091
source /opt/ros/noetic/setup.bash
# shellcheck disable=SC1091
[ -f "$WS/devel/setup.bash" ] && source "$WS/devel/setup.bash"

echo "[sensor] 工作区   : $WS"
echo "[sensor] 飞控串口 : $FCU_URL"
echo "[sensor] 雷达 launch: $LIDAR_LAUNCH"

if [ ! -e "$FCU_DEV" ]; then
  echo "[sensor] ⚠ 找不到 $FCU_DEV —— 设备名不对，或线没接。"
  echo "[sensor]   换板子后请改用自己板子上的设备口，例如 Jetson 用 /dev/ttyTHS1。"
  echo "[sensor]   详见 README 第四节 1；也可临时：FCU_URL=/dev/ttyTHS1:921600 ./start_sensor.sh"
else
  # 先放开权限，再做"能否打开"的判断，这样打不开就一定不是权限问题
  sudo chmod 777 "$FCU_DEV" 2>/dev/null || true

  # 用子 shell 试开：即使 exec 的重定向失败，也只影响子 shell，不会把本脚本带崩
  if ( exec 3<>"$FCU_DEV" ) 2>/dev/null; then
    echo "[sensor] $FCU_DEV 可正常打开，权限已放开"
    echo "[sensor]   （推荐改用 sudo usermod -aG dialout \$USER，之后就不需要这步）"
  else
    echo "[sensor] ⚠ $FCU_DEV 存在但打不开（mavros 会报 Input/output error）。"
    echo "[sensor]   这说明该 tty 背后没有可用的 UART，**不是**因为没接飞控"
    echo "[sensor]   —— UART 的 open 并不需要对面有设备。"
    echo "[sensor]   换板子后最常见：Jetson 的真串口是 /dev/ttyTHS*，/dev/ttyS* 多为占位节点。"
    echo "[sensor]   请改用你自己板子的设备口：FCU_URL=/dev/ttyTHS1:921600 ./start_sensor.sh"
    echo "[sensor]   （详见 README 第四节 1 的 python 探测脚本）"
  fi
fi

roslaunch px4ctrl mavros_px4.launch fcu_url:="$FCU_URL" &
sleep 3

# 把 MAVLink HIGHRES_IMU(id 105) 与 ATTITUDE_QUATERNION(id 31) 的推送间隔设为
# 5000us = 200 Hz，保证 px4ctrl 拿到高频 IMU / 姿态（MAV_CMD_SET_MESSAGE_INTERVAL=511）
rosrun mavros mavcmd long 511 105 5000 0 0 0 0 0 &
sleep 1
rosrun mavros mavcmd long 511 31 5000 0 0 0 0 0 &
sleep 1

# Livox 驱动：xfer_format=1 → livox_ros_driver2/CustomMsg，publish_freq=10Hz
# shellcheck disable=SC2086
exec roslaunch $LIDAR_LAUNCH


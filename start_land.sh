#!/usr/bin/env bash
# =============================================================================
# ⑦ 自动降落：px4ctrl 状态机 AUTO_HOVER → AUTO_LAND
#    以 0.3 m/s 下降，落地（des.z - odom.z < -0.5 m 且 |v| < 0.1 m/s 持续 3 s）后自动 disarm
#
# 注意：在 CMD_CTRL（手动遥控接管）状态下会被显式拒绝
# =============================================================================
set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source /opt/ros/noetic/setup.bash
# shellcheck disable=SC1091
[ -f "$WS/devel/setup.bash" ] && source "$WS/devel/setup.bash"

exec rostopic pub -1 /px4ctrl/takeoff_land quadrotor_msgs/TakeoffLand "takeoff_land_cmd: 2"

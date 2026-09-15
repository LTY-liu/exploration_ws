#!/usr/bin/env bash
# =============================================================================
# ⑥ 自动起飞：px4ctrl 状态机 MANUAL → AUTO_TAKEOFF
#    先 3.0 s 电机起转，再以 0.3 m/s 升到 0.6 m（ctrl_param_fpv.yaml: takeoff_height）
#
# 前提：RC 在 hover 档、机体静止、解锁条件满足；③ 已在运行
# =============================================================================
set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source /opt/ros/noetic/setup.bash
# shellcheck disable=SC1091
[ -f "$WS/devel/setup.bash" ] && source "$WS/devel/setup.bash"

exec rostopic pub -1 /px4ctrl/takeoff_land quadrotor_msgs/TakeoffLand "takeoff_land_cmd: 1"

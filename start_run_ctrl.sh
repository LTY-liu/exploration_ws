#!/usr/bin/env bash
# =============================================================================
# ③ 底层控制器 px4ctrl：~odom ← /Odom_high_freq，~cmd ← /position_cmd
#    参数来自 src/realflight_modules/px4ctrl/config/ctrl_param_fpv.yaml
# =============================================================================
set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source /opt/ros/noetic/setup.bash
# shellcheck disable=SC1091
[ -f "$WS/devel/setup.bash" ] && source "$WS/devel/setup.bash"

exec roslaunch px4ctrl run_ctrl.launch

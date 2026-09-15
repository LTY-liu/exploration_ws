#!/usr/bin/env bash
# =============================================================================
# ② FAST-LIO 建图：/livox/lidar + /livox/imu → /Odom_high_freq + /cloud_registered
#    rviz:=false 省机载算力（机载单板机必须关）
# =============================================================================
set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source /opt/ros/noetic/setup.bash
# shellcheck disable=SC1091
[ -f "$WS/devel/setup.bash" ] && source "$WS/devel/setup.bash"

exec roslaunch fast_lio mapping_mid360.launch rviz:=false

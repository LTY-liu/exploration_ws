#!/usr/bin/env bash
# =============================================================================
# （历史遗留脚本，真机流程不使用）
#
# 它启动的是 FUEL / ego-planner 上游的仿真入口 `ego_planner single_run_in_exp.launch`，
# 而 ego_planner 包**并不在本仓库内**（本仓库只有 fuel_planner 与真机模块）。
# 真机探索请用：
#     roslaunch exploration_manager exploration_real.launch
#
# 若你确实需要仿真入口，请把上游 uav_simulator / ego_planner 工作区一并放进来，
# 或用本仓库自带的 FUEL 仿真 launch：roslaunch exploration_manager exploration.launch
# =============================================================================
set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source /opt/ros/noetic/setup.bash
# shellcheck disable=SC1091
[ -f "$WS/devel/setup.bash" ] && source "$WS/devel/setup.bash"

if ! rospack find ego_planner >/dev/null 2>&1; then
  echo "错误：找不到 ego_planner 包（它不属于本仓库）。" >&2
  echo "真机探索请改用： roslaunch exploration_manager exploration_real.launch" >&2
  exit 1
fi

exec roslaunch ego_planner single_run_in_exp.launch

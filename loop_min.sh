#!/bin/bash
# ============================================================================
# loop_min.sh —— 最简版循环负载（让香橙派一直忙，用来测电池放电时间）
#
# 用法:
#     ./loop_min.sh ~/bags/flight.bag              最多跑 5 小时
#     ./loop_min.sh ~/bags/flight.bag 3600         最多跑 1 小时
#
# 停止:
#     BB响 一叫，按 Ctrl-C，屏幕会打印 TOTAL_SEC=... 这就是总时间
#
# 接电（重要）:
#     4S电池 --> 5V稳压模块 --> 香橙派      不接雷达、不接飞控
# ============================================================================

BAG="${1:?用法: ./loop_min.sh <bag文件> [最多秒数]}"
MAXT="${2:-18000}"

# 探索节点的 launch，如果和你们的不一样，改这一行
EXP_LAUNCH="exploration_manager exploration_real.launch"

[ -f "$BAG" ] || { echo "找不到 bag 文件: $BAG"; exit 1; }

T0=$(date +%s)
echo "=========================================="
echo " 开始时间 : $(date)"
echo " bag      : $BAG"
echo " 时间上限 : ${MAXT} 秒"
echo "=========================================="
echo " ★ 现在记下电池的静置电压"
echo " ★ BB响 叫了就按 Ctrl-C"
echo ""

trap 'pkill -f roslaunch; pkill -f "rosbag play"; sleep 2
      EL=$(( $(date +%s) - T0 ))
      echo ""
      echo "=========================================="
      echo " 结束时间 : $(date)"
      echo " TOTAL_SEC=$EL"
      echo " 也就是   : $(( EL / 60 )) 分 $(( EL % 60 )) 秒"
      echo "=========================================="
      echo " ★ 拔掉电池，静置 5~10 分钟后量末电压"
      exit 0' INT TERM

echo "[启动建图栈]"
roslaunch fast_lio mapping_mid360.launch rviz:=false > /tmp/loop_map.log 2>&1 &
sleep 8

while :; do
  EL=$(( $(date +%s) - T0 ))
  if [ "$EL" -ge "$MAXT" ]; then
    echo "到达时间上限，正常结束"
    break
  fi

  echo "[${EL}s] 启动探索节点 + 回放 bag ..."
  roslaunch $EXP_LAUNCH > /tmp/loop_exp.log 2>&1 &
  EXPPID=$!
  sleep 5

  rosbag play "$BAG" > /tmp/loop_bag.log 2>&1

  kill $EXPPID 2>/dev/null
  sleep 3

  EL=$(( $(date +%s) - T0 ))
  echo "[${EL}s] 跑完一轮，当前温度: $(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | tr '\n' ' ')"
done

pkill -f roslaunch
pkill -f "rosbag play"
sleep 2

EL=$(( $(date +%s) - T0 ))
echo ""
echo "=========================================="
echo " 结束时间 : $(date)"
echo " TOTAL_SEC=$EL"
echo " 也就是   : $(( EL / 60 )) 分 $(( EL % 60 )) 秒"
echo "=========================================="
echo " ★ 拔掉电池，静置 5~10 分钟后量末电压"

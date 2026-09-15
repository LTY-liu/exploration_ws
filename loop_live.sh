#!/bin/bash
# ============================================================================
# loop_live.sh —— 真实全栈循环负载（雷达/飞控照常，香橙派单独供电）
#
# 干什么:
#     建图栈常驻跑着，每隔 N 分钟重启一次探索节点，
#     保证规划负载不会因为"探索跑完了"而掉下去。
#
# 用法:
#     ./loop_live.sh                每 5 分钟重启一次探索，最多跑 5 小时
#     ./loop_live.sh 3 4            每 3 分钟重启一次，最多跑 4 小时
#
# 前提:
#     1. 已经跑过 ./start_sensor.sh   （mavros + 雷达驱动）
#     2. 香橙派由【测量电池】单独供电
#     3. 螺旋桨已拆除
#
# 停止:
#     BB响 一叫，按 Ctrl-C，屏幕会打印 TOTAL_SEC=... 这就是总时间
# ============================================================================

ROUND_MIN="${1:-5}"          # 每轮分钟数
MAX_HOUR="${2:-5}"           # 最多跑几小时

MAP_LAUNCH="fast_lio mapping_mid360.launch rviz:=false"
EXP_LAUNCH="exploration_manager exploration_real.launch"

ROUND_SEC=$(( ROUND_MIN * 60 ))
MAXT=$(( MAX_HOUR * 3600 ))

cpu_pct() {
  local a b c d
  read a b c d _ < /proc/stat
  local t1=$(( a + b + c + d )) i1=$d
  sleep 2
  read a b c d _ < /proc/stat
  local t2=$(( a + b + c + d )) i2=$d
  local dt=$(( t2 - t1 )) di=$(( i2 - i1 ))
  [ "$dt" -gt 0 ] && echo $(( (dt - di) * 100 / dt )) || echo 0
}

T0=$(date +%s)
echo "=============================================="
echo " 开始时间   : $(date)"
echo " 建图       : $MAP_LAUNCH"
echo " 探索       : $EXP_LAUNCH"
echo " 每轮       : ${ROUND_MIN} 分钟"
echo " 时间上限   : ${MAX_HOUR} 小时"
echo "=============================================="
echo " ★ 现在记下【测量电池】的静置电压"
echo " ★ BB响 叫了就按 Ctrl-C"
echo " ★ 确认螺旋桨已拆除、香橙派由测量电池单独供电"
echo ""

trap 'pkill -f roslaunch; pkill -f "rosbag play"; sleep 2
      EL=$(( $(date +%s) - T0 ))
      echo ""
      echo "=============================================="
      echo " 结束时间 : $(date)"
      echo " TOTAL_SEC=$EL"
      echo " 也就是   : $(( EL / 60 )) 分 $(( EL % 60 )) 秒"
      echo "=============================================="
      echo " ★ 拔掉测量电池，静置 5~10 分钟后量末电压"
      exit 0' INT TERM

echo "[启动建图栈]"
roslaunch $MAP_LAUNCH > /tmp/live_map.log 2>&1 &
sleep 10
echo "  建图已起，当前 CPU: $(cpu_pct)%"

N=0
while :; do
  EL=$(( $(date +%s) - T0 ))
  if [ "$EL" -ge "$MAXT" ]; then
    echo "到达时间上限，正常结束"
    break
  fi

  N=$(( N + 1 ))
  echo "[${EL}s] 第 $N 轮：启动探索节点"
  roslaunch $EXP_LAUNCH > /tmp/live_exp.log 2>&1 &
  EXPPID=$!

  # 跑满一轮，期间每 30 秒报一次状态
  for _ in $(seq 1 $(( ROUND_SEC / 30 ))); do
    sleep 30
    EL=$(( $(date +%s) - T0 ))
    echo "  [${EL}s] CPU $(cpu_pct)%   温度 $(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | tr '\n' ' ')"
  done

  echo "[${EL}s] 第 $N 轮结束，重启探索节点"
  kill $EXPPID 2>/dev/null
  pkill -f exploration_node 2>/dev/null
  wait $EXPPID 2>/dev/null
  sleep 3
done

pkill -f roslaunch
sleep 2

EL=$(( $(date +%s) - T0 ))
echo ""
echo "=============================================="
echo " 结束时间 : $(date)"
echo " TOTAL_SEC=$EL"
echo " 也就是   : $(( EL / 60 )) 分 $(( EL % 60 )) 秒"
echo "=============================================="
echo " ★ 拔掉测量电池，静置 5~10 分钟后量末电压"

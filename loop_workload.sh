#!/usr/bin/env bash
# ============================================================================
# loop_workload.sh —— 恒定、可重复的全栈循环负载（用于电池放电法测功耗）
#
# 用途
#   配合《功耗测量SOP.md》的"电池放电法"：让香橙派以【恒定且贴近真实飞行】
#   的负载连续运行 30~60 分钟，期间用电池放电时间反推平均功率。
#
#   ⚠️ 关键设计：本脚本【不需要接激光雷达】。
#      用 rosbag 回放 /livox/lidar + /livox/imu 喂真实的 FAST-LIO + FUEL 栈，
#      因此测量电池可以【只给香橙派供电】，口径干净，不必把雷达算进来。
#
# 两种模式
#   replay    （推荐）回放 bag + 真实 FAST-LIO + FUEL 探索 —— 负载就是真实负载
#   synthetic （备用）占空比可控的合成负载 —— 没有 bag 或 ROS 环境不可用时
#
# 停止方式（三种，任选）
#   1) 定时     --duration 3600            跑满 1 小时自动停，打印总时间
#   2) 电压自停  --stop-voltage 11.4 --voltage-cmd "<读电压的命令>"
#              每 15 秒查一次电压，低于阈值自动停（需要外部能读到电池电压）
#   3) 手工停   随时按 Ctrl-C，脚本会收尾并打印总时间
#
# 用法
#   # 先做一次环境自检（不会真的跑）
#   ./loop_workload.sh --check --bag ~/bags/flight.bag
#
#   # 推荐：回放模式，跑 60 分钟（定时停）
#   ./loop_workload.sh --mode replay --bag ~/bags/flight.bag --duration 3600
#
#   # 电压自停（若 PX4 接在同一条电池上，可用 mavros 读电压）
#   ./loop_workload.sh --mode replay --bag ~/bags/flight.bag --duration 7200 \
#       --stop-voltage 11.4 --voltage-cmd "rostopic echo -n1 /mavros/battery/voltage"
#
#   # 备用：合成负载，60% 占空比跑 45 分钟
#   ./loop_workload.sh --mode synthetic --cpu-load 0.6 --duration 2700
#
# 退出时自动：杀掉所有子进程、关闭 ROS 节点、打印总时间与负载统计
# ============================================================================
set -u

# ----------------------------------------------------------------- 默认值
MODE=replay
DURATION=3600                 # 总时长（秒）
OUTDIR="$HOME/loop_workload_logs"
BAG=""
BAG_ARGS=""                   # 追加给 rosbag play 的参数，如 "--clock"
ROS_SETUP=/opt/ros/noetic/setup.bash
WS_SETUP="$HOME/exploration_ws/devel/setup.bash"
MAPPING_LAUNCH="fast_lio mapping_mid360.launch rviz:=false"
EXPLORATION_LAUNCH="exploration_manager exploration_real.launch"
SETTLE=3                      # 每个循环之间空档（秒）
RESTART_STACK=0               # 1 = 每个循环连建图栈一起重启
GOVERNOR=""                   # 非空则锁定该 governor（如 performance）
CPU_LOAD=0.6
CPU_WORKERS=""
CHUNK_MS=20
IO_WORKERS=0
NET_TARGET=""
DO_CHECK=0
STOP_VOLTAGE=""               # 总电压降到该值以下就自动停（V）；为空=不启用
VOLTAGE_CMD=""                # 输出当前电池总电压的命令，如 rostopic echo -n1 /mavros/battery/voltage
VOLTAGE_EVERY=15              # 每多少秒查一次电压

usage() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)             MODE="$2"; shift 2 ;;
    --bag)              BAG="$2"; shift 2 ;;
    --bag-args)         BAG_ARGS="$2"; shift 2 ;;
    --duration)         DURATION="$2"; shift 2 ;;
    --outdir)           OUTDIR="$2"; shift 2 ;;
    --ros-setup)        ROS_SETUP="$2"; shift 2 ;;
    --ws-setup)         WS_SETUP="$2"; shift 2 ;;
    --mapping-launch)   MAPPING_LAUNCH="$2"; shift 2 ;;
    --exploration-launch) EXPLORATION_LAUNCH="$2"; shift 2 ;;
    --settle)           SETTLE="$2"; shift 2 ;;
    --restart-stack)    RESTART_STACK=1; shift ;;
    --governor)         GOVERNOR="$2"; shift 2 ;;
    --cpu-load)         CPU_LOAD="$2"; shift 2 ;;
    --cpu-workers)      CPU_WORKERS="$2"; shift 2 ;;
    --chunk-ms)         CHUNK_MS="$2"; shift 2 ;;
    --io)               IO_WORKERS="$2"; shift 2 ;;
    --net)              NET_TARGET="$2"; shift 2 ;;
    --stop-voltage)     STOP_VOLTAGE="$2"; shift 2 ;;
    --voltage-cmd)      VOLTAGE_CMD="$2"; shift 2 ;;
    --voltage-every)    VOLTAGE_EVERY="$2"; shift 2 ;;
    --check)            DO_CHECK=1; shift ;;
    -h|--help)          usage ;;
    *) echo "未知参数: $1"; usage ;;
  esac
done

mkdir -p "$OUTDIR"
STAMP=$(date +%Y%m%d_%H%M%S)
LOG="$OUTDIR/loop_${STAMP}"
TEL_CSV="${LOG}_telemetry.csv"
RUN_LOG="${LOG}.log"
SUMMARY="${LOG}_summary.txt"
STOPFILE="${LOG}.STOP"        # 该文件一旦出现，主循环就收尾
VLOG="${LOG}_voltage.csv"     # 电压记录

CHILDREN=()
START_EPOCH=0
CYCLES=0
STOP=0                        # 1 = 收到中断信号
STOP_REASON="跑满设定时长"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }

# ------------------------------------------------------------ 环境自检
check_env() {
  local ok=1
  echo "=========== 环境自检 ==========="

  if [ "$MODE" = replay ]; then
    echo -n "  rosbag play      : "
    command -v rosbag >/dev/null 2>&1 && echo OK || { echo "缺失"; ok=0; }
    echo -n "  roslaunch        : "
    command -v roslaunch >/dev/null 2>&1 && echo OK || { echo "缺失"; ok=0; }
    echo -n "  bag 文件         : "
    if [ -n "$BAG" ] && [ -f "$BAG" ]; then
      echo "$BAG ($(du -h "$BAG" | cut -f1))"
    else
      echo "未指定或不存在 —— 必须用 --bag 指定"; ok=0
    fi
    echo -n "  ROS setup        : "
    [ -f "$ROS_SETUP" ] && echo "$ROS_SETUP" || { echo "不存在: $ROS_SETUP"; ok=0; }
    echo -n "  工作区 setup     : "
    [ -f "$WS_SETUP" ] && echo "$WS_SETUP" || echo "不存在: $WS_SETUP（若已写入 .bashrc 可忽略）"
  else
    echo -n "  stress-ng        : "
    command -v stress-ng >/dev/null 2>&1 && echo "有（将使用）" || echo "无（改用 python3 占空比负载）"
    echo -n "  python3          : "
    command -v python3 >/dev/null 2>&1 && echo OK || { echo "缺失"; ok=0; }
    echo -n "  loop_cpu_worker  : "
    local w
    w="$(dirname "$0")/loop_cpu_worker.py"
    [ -f "$w" ] && echo "$w" || { echo "缺失: $w"; ok=0; }
    [ "$IO_WORKERS" -gt 0 ] && {
      echo -n "  fio              : "
      command -v fio >/dev/null 2>&1 && echo OK || echo "缺失（--io 将被忽略）"
    }
  fi

  echo ""
  echo -n "  governor         : "
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "读不到"
  echo -n "  CPU 核数         : "; nproc
  echo -n "  当前温度         : "
  for tz in /sys/class/thermal/thermal_zone*; do
    n=$(cat "$tz/type" 2>/dev/null); v=$(cat "$tz/temp" 2>/dev/null)
    [ -n "$v" ] && { [ "$v" -gt 1000 ] 2>/dev/null && v=$((v/1000)); printf '%s=%sC ' "$n" "$v"; }
  done
  echo ""
  echo -n "  可用内存         : "; free -h 2>/dev/null | awk '/^Mem/{print $7" available"}'
  echo ""
  echo "================================"
  [ "$ok" -eq 1 ] && echo "自检结果：可以开跑" || echo "自检结果：有缺失项，请先补齐"
  return $((1 - ok))
}

if [ "$DO_CHECK" -eq 1 ]; then
  check_env
  exit $?
fi

# ------------------------------------------------------------ 遥测采样
read_procstat() {
  awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5+$6}' /proc/stat
}
read_freqs() {
  local out="" p
  for p in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
    [ -r "$p" ] && out="$out$(cat "$p" 2>/dev/null)|"
  done
  echo "${out%|}"
}
read_temps() {
  local out="" tz n v
  for tz in /sys/class/thermal/thermal_zone*; do
    n=$(cat "$tz/type" 2>/dev/null); v=$(cat "$tz/temp" 2>/dev/null)
    [ -n "$v" ] || continue
    [ "$v" -gt 1000 ] 2>/dev/null && v=$((v/1000))
    out="$out ${n}=${v}"
  done
  echo "$out"
}
max_temp() {
  read_temps | tr ' ' '\n' | sed -n 's/.*=\([0-9-]*\)$/\1/p' \
    | sort -n | tail -1
}

sampler() {
  echo "t_s,duty_pct,freqs_khz,tmax_C,loadavg1,zones" > "$TEL_CSV"
  local prev=0 prev_idle=0 cur=0 cur_idle=0 dt=0 di=0 duty=0 n=0 el=0
  read prev prev_idle < <(read_procstat)
  while :; do
    sleep 2
    read cur cur_idle < <(read_procstat)
    dt=$(( cur - prev )); di=$(( cur_idle - prev_idle ))
    prev=$cur; prev_idle=$cur_idle
    duty=0
    [ "$dt" -gt 0 ] && duty=$(( (dt - di) * 100 / dt ))
    el=$(( $(date +%s) - START_EPOCH ))
    printf '%s,%s,%s,%s,%s,"%s"\n' \
      "$el" "$duty" "$(read_freqs)" \
      "$(max_temp)" "$(cut -d' ' -f1 /proc/loadavg)" "$(read_temps)" >> "$TEL_CSV"
    n=$(( n + 1 ))
    # 每 30 秒打一次"心跳"，让你能随时看到跑了多久
    if [ $(( n % 15 )) -eq 0 ]; then
      log "  已跑 ${el}s  CPU $(printf '%3d' "$duty")%  最高温 $(max_temp)C"
    fi
  done
}

# ------------------------------------------------------------ 清理
cleanup() {
  echo ""
  log "=== 清理 ==="
  for p in "${CHILDREN[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  pkill -f 'roslaunch' 2>/dev/null
  pkill -f 'rosbag play' 2>/dev/null
  pkill -f 'loop_cpu_worker' 2>/dev/null
  pkill -f 'stress-ng' 2>/dev/null
  sleep 1
  # 二次确认
  pkill -9 -f 'loop_cpu_worker' 2>/dev/null
  if [ -n "$GOVERNOR" ]; then
    log "governor 保持为 $GOVERNOR（按你的要求锁定，未还原）"
  fi
  log "已清理子进程"
}
# Ctrl-C：不立刻退出，先让主循环收尾（这样汇总和总时间才会打印出来）
on_int()  { STOP=1; STOP_REASON="手动中断 (Ctrl-C)"; echo ""; log "收到 Ctrl-C，等当前动作结束就收尾并打印总时间…"; }
on_term() { STOP=1; STOP_REASON="收到 TERM 信号"; }

trap on_int  INT
trap on_term TERM
trap cleanup EXIT

# ------------------------------------------------------------ 电压监测
# 香橙派自己读不到电池电压，所以必须由外部命令提供（--voltage-cmd）。
# 若没有这样的命令，就只用 --duration 定时停，或手工按 Ctrl-C 停。
voltage_watcher() {
  while :; do
    sleep "$VOLTAGE_EVERY"
    [ -e "$STOPFILE" ] && exit 0
    [ "$STOP" -eq 1 ] && exit 0
    local v
    v=$(eval "$VOLTAGE_CMD" 2>/dev/null | tr -d ' \r\t' | head -1)
    case "$v" in ''|*[!0-9.]*) continue ;; esac
    echo "$(( $(date +%s) - START_EPOCH )),$v" >> "$VLOG"
    log "  电压检查: ${v} V  （停止阈值 ${STOP_VOLTAGE} V）"
    if awk -v a="$v" -v b="$STOP_VOLTAGE" 'BEGIN{exit !(a<=b)}'; then
      echo "voltage $v <= $STOP_VOLTAGE at t=$(( $(date +%s) - START_EPOCH ))s" > "$STOPFILE"
      STOP_REASON="电压降到 ${v} V（阈值 ${STOP_VOLTAGE} V）"
      # 把正在阻塞的前台负载踢掉，好让主循环尽快走到收尾
      pkill -f 'rosbag play' 2>/dev/null
      pkill -f 'stress-ng' 2>/dev/null
      pkill -f 'loop_cpu_worker' 2>/dev/null
      exit 0
    fi
  done
}

# ------------------------------------------------------------ 前置
log "=== loop_workload.sh 启动 ==="
log "模式=$MODE  时长=${DURATION}s  输出=$OUTDIR"

[ "$MODE" = replay ] && { [ -f "$BAG" ] || { log "错误：bag 不存在：$BAG"; exit 1; }; }
[ "$MODE" = synthetic ] && [ -z "$CPU_WORKERS" ] && CPU_WORKERS=$(nproc)

if [ -n "$GOVERNOR" ]; then
  log "锁定 governor = $GOVERNOR"
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "$GOVERNOR" > "$g" 2>/dev/null
  done
fi
GOV_NOW=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
log "当前 governor = $GOV_NOW  （务必记进报告）"
log "起始温度:$(read_temps)"

# 启动遥测（必须在 START_EPOCH 赋值之后 fork，否则子 shell 看不到 t0）
# 见下方主循环：sampler 在主循环前启动

# ------------------------------------------------------------ 负载
start_mapping() {
  [ "$MODE" = replay ] || return 0
  log "  启动建图栈: roslaunch $MAPPING_LAUNCH"
  # shellcheck disable=SC2086
  roslaunch $MAPPING_LAUNCH >> "$RUN_LOG" 2>&1 &
  CHILDREN+=($!)
}

start_synthetic() {
  local w
  w="$(dirname "$0")/loop_cpu_worker.py"
  if command -v stress-ng >/dev/null 2>&1; then
    local pct
    pct=$(awk -v l="$CPU_LOAD" 'BEGIN{printf "%d", l*100}')
    log "  合成负载: stress-ng --cpu $CPU_WORKERS --cpu-load $pct"
    stress-ng --cpu "$CPU_WORKERS" --cpu-load "$pct" --timeout "${DURATION}s" \
      >> "$RUN_LOG" 2>&1 &
    CHILDREN+=($!)
  else
    log "  合成负载: $CPU_WORKERS x loop_cpu_worker.py --load $CPU_LOAD"
    local i
    for i in $(seq 1 "$CPU_WORKERS"); do
      python3 "$w" --load "$CPU_LOAD" --chunk-ms "$CHUNK_MS" >> "$RUN_LOG" 2>&1 &
      CHILDREN+=($!)
    done
  fi

  if [ "$IO_WORKERS" -gt 0 ] && command -v fio >/dev/null 2>&1; then
    log "  存储负载: fio x $IO_WORKERS"
    local i
    for i in $(seq 1 "$IO_WORKERS"); do
      fio --name=iow$i --rw=randrw --bs=128k --size=256M \
          --filename="/tmp/loop_fio_$i.dat" --direct=1 \
          --runtime="${DURATION}" --time_based >> "$RUN_LOG" 2>&1 &
      CHILDREN+=($!)
    done
  fi

  if [ -n "$NET_TARGET" ] && command -v iperf3 >/dev/null 2>&1; then
    log "  网络负载: iperf3 -> $NET_TARGET"
    iperf3 -c "$NET_TARGET" -t "$DURATION" -P 4 >> "$RUN_LOG" 2>&1 &
    CHILDREN+=($!)
  fi
}

run_replay_cycle() {
  CYCLES=$((CYCLES + 1))
  log "--- 循环 #$CYCLES ---"

  # 探索节点：每个循环重启，保证地图/状态复位，负载可重复
  log "  启动探索栈: roslaunch $EXPLORATION_LAUNCH"
  roslaunch $EXPLORATION_LAUNCH >> "$RUN_LOG" 2>&1 &
  local exp_pid=$!
  CHILDREN+=("$exp_pid")
  sleep 3

  log "  回放 bag: rosbag play $BAG_ARGS $BAG"
  # shellcheck disable=SC2086
  rosbag play $BAG_ARGS "$BAG" >> "$RUN_LOG" 2>&1

  sleep "$SETTLE"
  kill "$exp_pid" 2>/dev/null
  wait "$exp_pid" 2>/dev/null

  if [ "$RESTART_STACK" -eq 1 ]; then
    log "  重启建图栈"
    pkill -f 'fast_lio' 2>/dev/null
    sleep 2
    start_mapping
    sleep 5
  fi
}

# ------------------------------------------------------------ 主循环
START_EPOCH=$(date +%s)
sampler &
CHILDREN+=($!)
log "遥测 -> $TEL_CSV"

if [ -n "$STOP_VOLTAGE" ] && [ -n "$VOLTAGE_CMD" ]; then
  echo "t_s,voltage_V" > "$VLOG"
  voltage_watcher &
  CHILDREN+=($!)
  log "电压监测已启用：每 ${VOLTAGE_EVERY}s 查一次，低于 ${STOP_VOLTAGE} V 自动停"
  log "电压记录 -> $VLOG"
else
  log "电压监测【未启用】（需同时给出 --stop-voltage 和 --voltage-cmd）"
  log "  -> 将按 --duration 定时停止；也可以随时按 Ctrl-C 手工停"
fi

log "=== 负载开始，计时起点 t=0 ==="
log "★ 现在请记录电池起始【静置】电压 V_start"

should_stop() {
  [ "$STOP" -eq 1 ] && return 0
  [ -e "$STOPFILE" ] && return 0
  return 1
}

if [ "$MODE" = replay ]; then
  # 建图栈常驻（它是主要负载，常驻可避免循环间空档造成偏低偏差）
  start_mapping
  sleep 8

  while :; do
    should_stop && break
    EL=$(( $(date +%s) - START_EPOCH ))
    [ "$EL" -ge "$DURATION" ] && break
    run_replay_cycle
    should_stop && break
  done
else
  start_synthetic
  while :; do
    should_stop && break
    EL=$(( $(date +%s) - START_EPOCH ))
    [ "$EL" -ge "$DURATION" ] && break
    sleep 5
  done
fi

ELAPSED=$(( $(date +%s) - START_EPOCH ))
log "=== 负载结束，总时长 ${ELAPSED}s ==="
log "★ 现在请立即断开负载，静置 5~10 分钟后记录电池终止电压 V_end"

# ------------------------------------------------------------ 汇总
MEAN_DUTY=0; MEAN_TMAX=0; N=0
if [ -s "$TEL_CSV" ]; then
  read -r MEAN_DUTY MEAN_TMAX N < <(
    awk -F, 'NR>1 && $2!="" {d+=$2; t+=$4; n++} END{
      if(n>0) printf "%.1f %.1f %d", d/n, t/n, n; else print "0 0 0"}' "$TEL_CSV"
  )
fi

{
  echo "loop_workload.sh 汇总"
  echo "  模式            : $MODE"
  echo "  governor        : $GOV_NOW"
  echo "  停止原因        : $STOP_REASON"
  echo "  ELAPSED_TOTAL_SEC=$ELAPSED"
  echo "  完成循环数      : $CYCLES"
  echo "  平均 CPU 占用   : ${MEAN_DUTY}%"
  echo "  平均最高温度    : ${MEAN_TMAX} C"
  echo "  遥测样本数      : $N"
  echo "  遥测文件        : $TEL_CSV"
  [ -f "$VLOG" ] && echo "  电压文件        : $VLOG"
  echo "  运行日志        : $RUN_LOG"
} | tee "$SUMMARY"

echo ""
echo "============================================================================"
echo " 电池放电法计算（照抄进报告）"
echo "============================================================================"
echo ""
echo "  你需要的两个时间："
echo "    t_标 = 用【已知功率负载】标定同一块电池、同一电压区间所需时间（秒）"
echo "    t_测 = $ELAPSED 秒   ← 本次测量的实际时长"
echo ""
echo "  计算平台平均功率："
echo ""
echo "      P = (P_标 × t_标) / t_测"
echo ""
echo "  其中 P_标 是标定负载的已知功率（W）。"
echo ""
echo "  若没有做标定，退而用容量法："
echo "      E = C_区间(Ah) × V_均(V)        # V_均 用遥测/手工记录的平均电压"
echo "      P = E(W·h) / (t_测 / 3600) h"
echo ""
echo "  ⚠️ 报告里必须注明：governor = $GOV_NOW，环境温度 __ C，"
echo "     以及本次负载是否包含激光雷达（本脚本模式=$MODE 不驱动雷达硬件）。"
echo ""
echo "  负载恒定性佐证：平均 CPU 占用 ${MEAN_DUTY}%，平均最高温度 ${MEAN_TMAX} C"
echo "  （遥测 CSV 可作为附录，证明测量期间负载稳定）"
echo "============================================================================"

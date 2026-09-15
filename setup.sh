#!/usr/bin/env bash
# =============================================================================
# setup.sh —— 一键把本工程（exploration_ws）在「全新 Ubuntu 20.04 + ROS Noetic」
#             上编译成功。适用于任何克隆路径。
#
# 快速使用（在一个干净的 Ubuntu 20.04 上）：
#     git clone <REPO_URL> ~/exploration_ws
#     cd ~/exploration_ws
#     bash setup.sh
#     source devel/setup.bash
#
# 它会依次完成：
#   1) 系统依赖（apt：Eigen/PCL/OpenCV/Boost/Armadillo/APR/Qt5/python3-dev ...）
#   2) ROS Noetic（未安装时自动装；arm64 也有官方 arm64 deb）
#   3) 校验 NLopt 就位（源码已内置在仓库里，离线编译，无需联网）
#   4) 校验 Livox-SDK2 与 livox_ros_driver2/package.xml 就位
#   5) catkin_make 全量编译 + 产物与 launch 校验
#
# ★ 离线构建：NLopt 与 Livox-SDK2 的源码都已随仓库分发，`git clone` 之后
#   断网也能完整编译；本脚本的联网部分只有第 1、2 步的 apt/ROS（这两个是
#   系统级前置依赖，请在联网环境下装一次）。
#
# 可选参数：
#   bash setup.sh --check         只做环境自检，不改动系统
#   bash setup.sh --offline       离线模式（= --skip-apt --skip-ros）：只编译，
#                                 不碰网络。适用于 ROS 与系统依赖已装好的机器
#   bash setup.sh --skip-apt      跳过系统 apt 安装
#   bash setup.sh --skip-ros      跳过 ROS 安装
#   bash setup.sh --skip-nlopt    跳过 NLopt 检查
#   bash setup.sh --skip-build    只装依赖、不编译
#   bash setup.sh --jobs 2        指定并行度（arm64 单板机建议 2~4，避免 OOM）
#   bash setup.sh --yes           全自动，不再交互确认
# =============================================================================
set -uo pipefail

# ----------------------------------------------------------------- 参数
WS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROSDISTRO="noetic"
NLOPT_VER="2.7.1"
JOBS=""
DO_CHECK=0
DO_APT=1
DO_ROS=1
DO_NLOPT=1
DO_BUILD=1
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check)      DO_CHECK=1; shift ;;
    --offline)    DO_APT=0; DO_ROS=0; shift ;;   # 等价于 --skip-apt --skip-ros
    --skip-apt)   DO_APT=0; shift ;;
    --skip-ros)   DO_ROS=0; shift ;;
    --skip-nlopt) DO_NLOPT=0; shift ;;
    --skip-build) DO_BUILD=0; shift ;;
    --jobs)       JOBS="$2"; shift 2 ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1（用 --help 看用法）"; exit 1 ;;
  esac
done

C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
step() { echo; echo "${C_B}==== $* ====${C_0}"; }
ok()   { echo "  ${C_G}OK${C_0}   $*"; }
warn() { echo "  ${C_Y}WARN${C_0} $*"; }
bad()  { echo "  ${C_R}FAIL${C_0} $*"; }
die()  { echo; echo "${C_R}中止: $*${C_0}" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ -z "$JOBS" ]; then
  N="$(nproc 2>/dev/null || echo 2)"
  if [ "$N" -gt 4 ]; then JOBS=4; else JOBS="$N"; fi
fi

# ----------------------------------------------------------------- 0 前置
step "0. 环境概览"
[ -r /etc/os-release ] && . /etc/os-release
echo "  系统     : ${PRETTY_NAME:-未知}"
echo "  CPU 架构 : $(dpkg --print-architecture 2>/dev/null || uname -m)  ($(nproc) 核, -j$JOBS)"
echo "  工作区   : $WS"

if [ "${VERSION_ID:-}" != "20.04" ]; then
  warn "本脚本针对 Ubuntu 20.04 (Focal) + ROS Noetic 编写，当前 VERSION_ID=${VERSION_ID:-未知}"
  [ "$ASSUME_YES" -eq 1 ] || { read -r -p "  仍要继续？[y/N] " a; [ "$a" = "y" ] || exit 1; }
fi
[ -f "$WS/src/CMakeLists.txt" ] || die "没找到 $WS/src/CMakeLists.txt —— 请在本工作区根目录运行 setup.sh"
[ "$(id -u)" -ne 0 ] || die "请用普通用户运行（脚本内部自己调 sudo），不要 sudo bash setup.sh"

# ----------------------------------------------------------------- 自检
if [ "$DO_CHECK" -eq 1 ]; then
  step "自检 1/5：编译工具链"
  for c in cmake g++ git; do
    if have "$c"; then ok "$c → $(command -v "$c")"; else bad "$c 缺失"; fi
  done

  step "自检 2/5：ROS Noetic"
  if [ -f "/opt/ros/$ROSDISTRO/setup.bash" ]; then
    # shellcheck disable=SC1090
    source "/opt/ros/$ROSDISTRO/setup.bash"
    ok "ROS $ROSDISTRO 已安装"
    for p in pcl_ros cv_bridge eigen_conversions mavros rviz message_filters; do
      if rospack find "$p" >/dev/null 2>&1; then ok "包 $p"; else bad "包 $p 缺失"; fi
    done
  else
    bad "/opt/ros/$ROSDISTRO 不存在（ROS 未安装）"
  fi

  step "自检 3/5：系统库"
  for p in build-essential libeigen3-dev libpcl-dev libopencv-dev libboost-all-dev \
           libarmadillo-dev libapr1-dev qtbase5-dev python3-dev; do
    if dpkg -s "$p" >/dev/null 2>&1; then ok "apt $p"; else bad "apt $p 缺失"; fi
  done

  step "自检 4/5：NLopt（离线内置，不需要联网）"
  NLOPT_BUNDLED="$WS/src/fuel_planner/bspline_opt/thirdparty/nlopt"
  if [ -f "$NLOPT_BUNDLED/CMakeLists.txt" ]; then
    ok "内置 NLopt 源码就位（NLopt v$NLOPT_VER）→ 离线也能编"
  else
    bad "内置 NLopt 源码缺失：$NLOPT_BUNDLED/CMakeLists.txt"
  fi
  if ls /usr/local/lib/libnlopt.so* >/dev/null 2>&1; then
    ok "系统已装 NLopt（/usr/local/lib/libnlopt.so*），bspline_opt 会用系统的"
  elif [ -f /usr/include/nlopt.hpp ] || [ -f /usr/local/include/nlopt.hpp ]; then
    ok "系统已装 NLopt 头文件，bspline_opt 会用系统的"
  else
    ok "系统未装 NLopt（正常，将使用上面的内置源码）"
  fi

  step "自检 5/5：★ 本仓库自带的 Livox 相关文件"
  DRV="$WS/src/livox_ros_driver2"
  [ -f "$DRV/package.xml" ]    && ok "livox_ros_driver2/package.xml" \
    || bad "缺 livox_ros_driver2/package.xml（catkin 会看不到这个包）"
  [ -f "$DRV/launch_ROS1/msg_MID360.launch" ] && ok "livox_ros_driver2/launch_ROS1/msg_MID360.launch" \
    || bad "缺 livox_ros_driver2/launch_ROS1/msg_MID360.launch"
  if [ -d "$DRV/launch" ]; then
    bad "livox_ros_driver2/launch/ 与 launch_ROS1/ 并存 → roslaunch 会报 multiple files，需删除 launch/"
  fi
  if [ -f "$DRV/Livox-SDK2/CMakeLists.txt" ]; then
    if grep -q 'LivoxLidarDoubleEchoRawPoint' "$DRV/Livox-SDK2/include/livox_lidar_def.h" 2>/dev/null \
       && grep -q 'kLivoxLidarTypeMid360s' "$DRV/Livox-SDK2/include/livox_lidar_def.h" 2>/dev/null; then
      ok "livox_ros_driver2/Livox-SDK2/（版本可用）"
    else
      bad "livox_ros_driver2/Livox-SDK2/ 版本过旧（缺 DoubleEcho/Mid360s 定义）→ 编译 pub_handler.cpp 会报未声明"
    fi
  else
    bad "缺 livox_ros_driver2/Livox-SDK2/（驱动无法编译）"
  fi

  if [ -d "$WS/devel/lib" ]; then
    step "自检附加：编译产物"
    for e in livox_ros_driver2_node fastlio_mapping exploration_node traj_server \
             waypoint_generator odom_to_pose px4ctrl_node offline_mapper; do
      f="$(find "$WS/devel/lib" -name "$e" -type f 2>/dev/null | head -1)"
      [ -n "$f" ] && ok "$e" || bad "$e 未编译出"
    done
  fi
  echo
  echo "${C_B}自检结束。带 FAIL 的项请修好后再正式编译。${C_0}"
  exit 0
fi

# ----------------------------------------------------------------- 1 apt
if [ "$DO_APT" -eq 1 ]; then
  step "1/5. 系统依赖（apt）"
  sudo apt update || die "apt update 失败"
  sudo apt install -y \
    build-essential cmake git wget curl pkg-config lsb-release gnupg2 ca-certificates \
    libeigen3-dev \
    libpcl-dev \
    libopencv-dev \
    libboost-all-dev \
    libarmadillo-dev \
    libyaml-cpp-dev \
    libusb-1.0-0-dev \
    libapr1-dev libaprutil1-dev \
    qtbase5-dev libqt5core5a libqt5gui5 libqt5widgets5 \
    python3-dev python3-pip python3-numpy python3-yaml \
    net-tools iproute2 vim htop \
    || die "系统依赖安装失败"
  ok "系统依赖完成"

  # 可选：数据分析 / 功耗测量工具（失败不影响编译）
  sudo apt install -y python3-matplotlib python3-scipy python3-lz4 \
    stress-ng fio iperf3 sysstat || warn "可选工具未全装上（不影响编译与飞行）"
else
  step "1/5. 系统依赖（已跳过）"
fi

# ----------------------------------------------------------------- 2 ROS
if [ "$DO_ROS" -eq 1 ]; then
  step "2/5. ROS Noetic"
  if [ -f "/opt/ros/$ROSDISTRO/setup.bash" ]; then
    ok "ROS $ROSDISTRO 已安装，补齐所需包"
  else
    echo "  添加 ROS 源..."
    sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc \
      -o /usr/share/keyrings/ros-archive-keyring.gpg || die "下载 ROS 密钥失败（检查网络）"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros/ubuntu $(lsb_release -sc) main" \
      | sudo tee /etc/apt/sources.list.d/ros1.list >/dev/null
    sudo apt update || die "加 ROS 源后 apt update 失败"
    apt-cache show ros-noetic-ros-base >/dev/null 2>&1 \
      || die "当前架构 $(dpkg --print-architecture) 找不到 ros-noetic-ros-base"
  fi

  sudo apt install -y \
    ros-noetic-ros-base ros-noetic-catkin ros-noetic-cmake-modules \
    ros-noetic-rviz ros-noetic-rosbag ros-noetic-pcl-ros ros-noetic-cv-bridge \
    ros-noetic-image-transport ros-noetic-message-filters \
    ros-noetic-tf ros-noetic-tf2-ros ros-noetic-eigen-conversions \
    ros-noetic-visualization-msgs ros-noetic-dynamic-reconfigure ros-noetic-nodelet \
    ros-noetic-mavros ros-noetic-mavros-extras \
    || die "ROS 包安装失败（重点看 pcl-ros / eigen-conversions / mavros）"
  ok "ROS 包完成"

  if [ -x "/opt/ros/$ROSDISTRO/lib/mavros/install_geographiclib_datasets.sh" ]; then
    sudo "/opt/ros/$ROSDISTRO/lib/mavros/install_geographiclib_datasets.sh" \
      && ok "MAVROS 地理数据集已装" || warn "MAVROS 地理数据集安装失败"
  fi
else
  step "2/5. ROS Noetic（已跳过）"
fi

# ----------------------------------------------------------------- 3 NLopt
if [ "$DO_NLOPT" -eq 1 ]; then
  step "3/5. NLopt（离线内置，不需要联网）"
  # bspline_opt 需要 NLopt。它现在的查找顺序是：
  #   1) 系统里已安装的 NLopt（find_path / find_library，不再写死 /usr/local）
  #   2) 找不到就用仓库内置源码 src/fuel_planner/bspline_opt/thirdparty/nlopt
  #      现场编成静态库 libnlopt.a —— 整个过程不访问网络。
  # 所以这里只做检查与说明，不再下载、不再需要 sudo。
  if ls /usr/local/lib/libnlopt.so* >/dev/null 2>&1; then
    ok "系统已装 NLopt（/usr/local/lib/libnlopt.so*），bspline_opt 将直接使用"
  elif [ -f /usr/include/nlopt.hpp ] || [ -f /usr/local/include/nlopt.hpp ]; then
    ok "系统已装 NLopt 头文件，bspline_opt 将优先使用系统的"
  else
    ok "系统未装 NLopt —— 无需处理，将使用仓库内置源码离线编译"
  fi

  NLOPT_BUNDLED="$WS/src/fuel_planner/bspline_opt/thirdparty/nlopt"
  [ -f "$NLOPT_BUNDLED/CMakeLists.txt" ] \
    && ok "内置 NLopt 源码就位（NLopt v$NLOPT_VER，MIT 许可）" \
    || die "内置 NLopt 源码缺失：$NLOPT_BUNDLED/CMakeLists.txt（该目录随仓库分发，不需要联网下载）"
else
  step "3/5. NLopt（已跳过）"
fi

# ----------------------------------------------------------------- 4 仓库完整性与瘦身
step "4/5. 校验仓库自带文件"
DRV="$WS/src/livox_ros_driver2"

# 若 package.xml 缺失（旧 tag 或 .gitignore 误伤），现场从 package_ROS1.xml 生成
if [ ! -f "$DRV/package.xml" ] && [ -f "$DRV/package_ROS1.xml" ]; then
  warn "livox_ros_driver2/package.xml 缺失 → 从 package_ROS1.xml 生成"
  cp "$DRV/package_ROS1.xml" "$DRV/package.xml"
fi
[ -f "$DRV/package.xml" ] || die "livox_ros_driver2/package.xml 缺失，catkin 无法发现该包"

# ★ 注意：不要在 livox_ros_driver2 里再建一个 launch/ 目录！
#   ROS1 的 roslib.packages.find_resource 是「遍历整个包目录」找同名 launch 文件的，
#   同一个包内出现两份同名 launch 会直接报：
#       RLException: multiple files named [msg_MID360.launch] in package [livox_ros_driver2]
#   上游把 ROS1 的 launch 放在 launch_ROS1/ 里，roslaunch 照样能找到，
#   所以唯一的正确状态就是「只有 launch_ROS1/」。
LIDAR_PKG="$WS/src/livox_ros_driver2"
if [ -d "$LIDAR_PKG/launch" ]; then
  warn "检测到 livox_ros_driver2/launch/ 与 launch_ROS1/ 并存（会导致 roslaunch 报 multiple files）"
  warn "→ 正在删除多余副本：$LIDAR_PKG/launch"
  rm -rf "$LIDAR_PKG/launch"
fi
[ -f "$LIDAR_PKG/launch_ROS1/msg_MID360.launch" ] \
  || die "livox_ros_driver2/launch_ROS1/msg_MID360.launch 缺失"
ok "livox_ros_driver2/launch_ROS1/msg_MID360.launch 就位（且无同名副本）"

# ★ Livox-SDK2 必须在（驱动包 CMakeLists 会编译它），且必须是 ≥ v1.4.0 的新版本
SDK2="$DRV/Livox-SDK2"
SDK2_URL="https://github.com/Livox-SDK/Livox-SDK2.git"
SDK2_COMMIT="08f523c930b2f0ba1e98a6afaa8d7476bf479908"   # v1.4.3
check_sdk2() {  # 返回 0 = 版本可用
  [ -f "$SDK2/CMakeLists.txt" ] || return 1
  grep -q 'LivoxLidarDoubleEchoRawPoint' "$SDK2/include/livox_lidar_def.h" 2>/dev/null || return 1
  grep -q 'kLivoxLidarTypeMid360s'       "$SDK2/include/livox_lidar_def.h" 2>/dev/null || return 1
  return 0
}

if check_sdk2; then
  ok "Livox-SDK2 版本可用（含 DoubleEcho / Mid360s 定义）"
else
  if [ -d "$SDK2" ]; then
    warn "现有 $SDK2 版本过旧或残缺 → 重新获取"
    rm -rf "$SDK2"
  else
    warn "缺 $SDK2 → 从上游获取"
  fi
  echo "  注意：驱动 livox_ros_driver2 用到了 LivoxLidarDoubleEchoRawPoint、"
  echo "        kLivoxLidarDoubleEchoData、kLivoxLidarTypeMid360s 等符号，"
  echo "        只有 Livox-SDK2 ≥ v1.4.0 才提供（旧版会在编译 pub_handler.cpp 时报未声明）。"
  git clone --depth 1 "$SDK2_URL" "$SDK2" || die "克隆 Livox-SDK2 失败（检查网络）"
  ( cd "$SDK2" && git fetch --depth 1 origin "$SDK2_COMMIT" >/dev/null 2>&1 \
      && git checkout -q "$SDK2_COMMIT" ) || warn "未能切到固定 commit $SDK2_COMMIT（用 master 继续）"
  rm -rf "$SDK2/.git"
  check_sdk2 || die "Livox-SDK2 仍不满足版本要求，请手工检查 $SDK2/include/livox_lidar_def.h"
  ok "Livox-SDK2 获取完成"
fi

# 防御性排除：确认不会被编译的包都带 CATKIN_IGNORE
for d in \
  "$WS/src/realflight_modules/mid360_fastlio/src/livox_ros_driver2" \
  "$WS/src/realflight_modules/mid360_fastlio/src/livox_ros_driver/livox_ros_driver" ; do
  if [ -f "$d/package.xml" ] && [ ! -f "$d/CATKIN_IGNORE" ]; then
    warn "为上游重复副本添加 CATKIN_IGNORE：$d"
    printf 'duplicate/unused copy, excluded from catkin build\n' > "$d/CATKIN_IGNORE"
  fi
done

# ----------------------------------------------------------------- 5 编译
if [ "$DO_BUILD" -eq 1 ]; then
  step "5/5. catkin_make 全量编译（-j$JOBS，首次约 20~60 分钟）"
  cd "$WS" || die "cd $WS 失败"
  # shellcheck disable=SC1090
  source "/opt/ros/$ROSDISTRO/setup.bash"
  catkin_make -j"$JOBS" \
    || die "catkin_make 失败 —— 看上面第一条 error；常见原因：NLopt 不在 /usr/local、Livox-SDK2 缺失、eigen_conversions 未装"
  # shellcheck disable=SC1090
  source "$WS/devel/setup.bash"
  ok "编译完成"

  step "5b. 产物校验"
  MISS=0
  for e in livox_ros_driver2_node fastlio_mapping exploration_node traj_server \
           waypoint_generator odom_to_pose px4ctrl_node offline_mapper; do
    f="$(find "$WS/devel/lib" -name "$e" -type f 2>/dev/null | head -1)"
    if [ -n "$f" ]; then ok "$e"; else bad "$e 未编译出"; MISS=1; fi
  done

  step "5c. launch 文件解析校验（只解析、不起进程）"
  for l in "exploration_manager exploration_real.launch" \
           "fast_lio mapping_mid360.launch" \
           "px4ctrl run_ctrl.launch" \
           "px4ctrl mavros_px4.launch" \
           "livox_ros_driver2 msg_MID360.launch"; do
    # shellcheck disable=SC2086
    if roslaunch --nodes $l >/dev/null 2>&1; then ok "roslaunch $l"; else bad "roslaunch $l 解析失败"; MISS=1; fi
  done

  [ "$MISS" -eq 0 ] || die "有产物/launch 校验未通过，见上面的 FAIL 行"
else
  step "5/5. catkin_make（已跳过）"
fi

# ----------------------------------------------------------------- 收尾
step "完成。接下来需要手工做的（都是硬件相关，与编译无关）"
cat <<'EOF'
  1) 让当前 shell 能用到本工作区（写入 ~/.bashrc）：
       echo 'source /opt/ros/noetic/setup.bash'                >> ~/.bashrc
       echo "source $PWD/devel/setup.bash"                     >> ~/.bashrc
       echo 'export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib' >> ~/.bashrc

  2) 飞控串口：
       sudo usermod -aG dialout $USER      # 重新登录生效
       ls /dev/ttyS* /dev/ttyACM*          # ★ 确认设备名，默认配置假定 /dev/ttyS1
     端口名/波特率不同就改这里：src/realflight_modules/px4ctrl/launch/mavros_px4.launch

  3) 雷达网口静态 IP（Mid-360 默认 192.168.1.106，主机需为 192.168.1.5）：
       sudo tee /etc/netplan/60-livox.yaml >/dev/null <<'YAML'
       network:
         version: 2
         ethernets:
           eth0:                      # ★ 换成接雷达的网口名（ip -br link 查）
             dhcp4: false
             addresses: [192.168.1.5/24]
       YAML
       sudo chmod 600 /etc/netplan/60-livox.yaml && sudo netplan apply
       ping -c 2 192.168.1.106

  4) 机载单板机建议锁 CPU 频率：
       echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

  5) 起飞前的地面联调（不上桨）：
       ./start_sensor.sh      # 另开终端
       ./start_mapping.sh
       ./start_run_ctrl.sh
       roslaunch exploration_manager exploration_real.launch
       roslaunch exploration_manager rviz.launch      # Fixed Frame = world
EOF
echo
echo "${C_G}setup.sh 结束。${C_0}"

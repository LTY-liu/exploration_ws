# exploration_ws —— 四旋翼自主探索（FUEL + FAST-LIO + PX4/MAVROS）

一套跑在**机载计算机**上的真机自主探索工程：Livox Mid-360 激光雷达 → FAST-LIO 激光惯性里程计 → FUEL 前沿探索规划 → px4ctrl 底层控制 → PX4 飞控自动起降。全程无外部定位（无动捕 / 无 RTK）、无深度相机。

- 目标系统：**Ubuntu 20.04 (Focal) + ROS Noetic**
- 已在 **arm64（Orange Pi 5 / RK3588S）** 与 x86_64 上验证
- 飞行平台：自组四旋翼，PX4，Livox Mid-360（前倾 15° 安装）

---

## 一、快速开始（三条命令）

在**全新的 Ubuntu 20.04** 上：

```bash
git clone https://github.com/LTY-liu/exploration_ws.git ~/exploration_ws
cd ~/exploration_ws
bash setup.sh
```

`setup.sh` 会自动完成：系统依赖 → ROS Noetic → 校验 NLopt 与 Livox 驱动相关文件 → `catkin_make` 全量编译 → 产物与 launch 校验。

编译成功后让当前 shell 用上工作区：

```bash
source devel/setup.bash
```

### ★ 支持离线构建

`git clone` 之后**断网也能完整编译**：第三方依赖的源码（NLopt、Livox-SDK2）都已随仓库一起分发，构建过程不访问任何网络。

唯一需要联网的只有系统级前置依赖 —— 第 1 步的 apt 包和第 2 步的 ROS Noetic，请在**联网环境下装一次**；之后换到离线机器上，只要 `clone` + `bash setup.sh` 即可。若目标机已装好 ROS 与依赖，可以只跑：

```bash
bash setup.sh --skip-apt --skip-ros
```

### 先自检（可选，推荐）

```bash
bash setup.sh --check      # 只检查不改动系统，逐项列出缺什么
```

### 其它用法

```bash
bash setup.sh --skip-apt          # 跳过 apt（依赖已装好）
bash setup.sh --jobs 2            # 指定并行度（arm64 单板机建议 2~4，避免 OOM）
bash setup.sh --skip-build        # 只装依赖、不编译
```

> 如果你的系统是 **x86_64 桌面版**，脚本同样适用。
> 如果只想手工来，见本文末尾「手工编译步骤」。

---

## 二、编译前必须知道的三件事

这三条是本工程最容易卡住别人的地方，已经全部在仓库里处理好了，这里说明原因以免误改：

| # | 事项 | 现状 |
|---|---|---|
| 1 | **`bspline_opt` 需要 NLopt**。原先它的路径被写死成 `/usr/local/lib/libnlopt.so` 与 `/usr/local/include`，导致必须联网下载编译 NLopt 才能编过，且 `apt install libnlopt-dev` 完全无效（apt 版装在 `/usr/include` 与 `/usr/lib/<arch>-linux-gnu`） | 已改为：**优先用系统已装的 NLopt；找不到就用仓库内置源码离线编译**。内置源码 `src/fuel_planner/bspline_opt/thirdparty/nlopt/`（NLopt v2.7.1，MIT），产出静态库 `libnlopt.a`。想强制使用内置版本：`catkin_make -DBSplineOpt_USE_BUNDLED_NLOPT=ON` |
| 2 | **`src/livox_ros_driver2` 需要同目录下的 `Livox-SDK2/`**，而它不存在于上游 livox_ros_driver2 仓库中（该驱动包的 `CMakeLists.txt` 会在 configure 阶段编译它）。且**版本必须 ≥ v1.4.0**：驱动用到 `LivoxLidarDoubleEchoRawPoint`、`kLivoxLidarDoubleEchoData`、`kLivoxLidarTypeMid360s`（Mid-360S）、`kLivoxLidarTypeAvia2` 等符号，旧 SDK 编译 `pub_handler.cpp` 会报「未声明的标识符」 | 本仓库已内置 **Livox-SDK2 v1.4.3**（`src/livox_ros_driver2/Livox-SDK2/`，commit `08f523c`），clone 下来即完整、无需联网 |
| 3 | 上游 `livox_ros_driver2` 靠 `./build.sh ROS1` 现场生成 `package.xml`（并顺手把 `launch_ROS1/` 复制成 `launch/`）；但该脚本会 `rm -rf ../../{build,devel,install}` 并删掉 `src/CMakeLists.txt` | 本仓库已把 `package.xml`（来自 `package_ROS1.xml`）纳入版本管理，**不要再跑 `build.sh`**。⚠️ 也**不要**去建 `launch/` 副本：ROS1 的 `roslib` 是遍历整个包目录找同名 launch 文件的，`launch/` 与 `launch_ROS1/` 并存会直接报 `multiple files named [...]`。上游放在 `launch_ROS1/` 里，`roslaunch livox_ros_driver2 msg_MID360.launch` 照样能找到 |

> `src/realflight_modules/mid360_fastlio/src/livox_ros_driver2/` 是 FAST-LIO 上游自带的**重复副本**（含一份旧版 Livox-SDK2），已由 `CATKIN_IGNORE` 排除、不参与编译，可以被安全删除以减小仓库体积。

---

## 三、真机运行流程（7 步）

按顺序执行，每一步单独开一个终端：

| 步骤 | 命令 | 作用 |
|---|---|---|
| ① | `./start_sensor.sh` | 飞控串口授权 → MAVROS → 把 MAVLink `HIGHRES_IMU`(105) / `ATTITUDE_QUATERNION`(31) 设为 **200 Hz** → 启动 Mid-360 驱动 |
| ② | `./start_mapping.sh` | FAST-LIO：`/livox/lidar` + `/livox/imu` → `/Odom_high_freq`(~200 Hz)、`/cloud_registered` |
| ③ | `./start_run_ctrl.sh` | px4ctrl 底层控制：`~odom←/Odom_high_freq`，`~cmd←/position_cmd` |
| ④ | `roslaunch exploration_manager exploration_real.launch` | 探索算法主体（`exploration_node` / `traj_server` / `waypoint_generator` / `odom_to_pose`） |
| ⑤ | `roslaunch exploration_manager rviz.launch` | 人机界面，Fixed Frame = `world` |
| ⑥ | `./start_takeoff.sh` | 自动起飞 → 0.6 m 悬停 |
| ⑦ | `./start_land.sh` | 自动降落并 disarm |

**探索触发**：悬停稳定后在 RViz 里用 **2D Nav Goal** 点一下即开始探索。

> ⚠️ 注意：出厂配置里 `px4ctrl` 在进入悬停约 2 s 后会**自动**发 `/traj_start_trigger`，而 `exploration_real.launch` 把 `waypoint_generator` 的 `~traj_start_trigger` remap 到了全局话题、且 `waypoint_type=point` —— 结果是**不点也会自动开跑**。若要改成手动触发，见 `HANDOVER_2026-09-06.md` 的 P2 修复。

### 关键话题

| 话题 | 说明 |
|---|---|
| `/Odom_high_freq` | FAST-LIO 里程计（~200 Hz） |
| `/cloud_registered` | 世界系注册点云（喂 FUEL 地图） |
| `/map_ros/pose` | `fuel_bridge` 输出的 PoseStamped（供地图 ray casting） |
| `/position_cmd` | `traj_server` → `px4ctrl` |
| `/planning/bspline`、`/waypoint_generator/waypoints`、`/traj_start_trigger` | 规划与触发 |
| `/sdf_map/occupancy_all`、`/sdf_map/virtual_wall` | 地图与飞行安全盒可视化 |
| `/mavros/*` | MAVROS 桥接 |

---

## 四、硬件相关配置（换机器必看）

`setup.sh` 不会碰这些，因为都与你的接线/网络有关：

### 1. 飞控串口

默认配置假定飞控接在 **`/dev/ttyS1`，波特率 921600**。**这个默认值只在 Orange Pi 一类板子上成立**，
换板子（尤其是 Jetson）后必须重新确认。

**先跑这 5 行，直接告出哪几个 tty 是真能打开的**：

```bash
python3 - <<'EOF'
import os, glob
for dev in sorted(glob.glob('/dev/ttyTHS*') + glob.glob('/dev/ttyS*') +
                  glob.glob('/dev/ttyACM*') + glob.glob('/dev/ttyUSB*')):
    try:
        fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        os.close(fd)
        print(f"  可用   {dev}")
    except OSError as e:
        print(f"  打不开 {dev}  -> {e.strerror}")
EOF
```

#### ⚠️ `FCU: DeviceError:serial:open: Input/output error` 怎么解

mavros 的这行报错是 `open(2)` 返回的 **errno 5 (EIO)**，含义要和对错区分开：

| 报错 | 含义 |
|---|---|
| `No such file or directory` | 设备节点不存在 |
| `Permission denied` | 权限不够（`sudo usermod -aG dialout $USER`） |
| `Device or resource busy` | 被别的进程占用 |
| **`Input/output error`** | **节点存在，但它背后没有可用的 UART** |

结论：**EIO 是独立故障，接上飞控也大概率不通**。因为 UART 的 `open()` 并不需要对面有设备——
就算飞控一根线没接，只要节点是真串口，open 也会成功，mavros 之后才会报「收不到心跳」。

**板子差异（换板子最常踩）**：

| | Orange Pi / 树莓派 | Jetson (L4T) |
|---|---|---|
| 真实 UART | `/dev/ttyS1`、`/dev/ttyS0` | **`/dev/ttyTHS0`、`/dev/ttyTHS1`…**（Tegra HSUART） |
| `/dev/ttyS*` | 就是真串口 | 常为 8250 **占位节点**，`open()` 直接 EIO |

**Jetson 额外两个坑**：

```bash
# ① nvgetty 占着串口（L4T 默认把 ttyTHS0 当串口控制台）
sudo systemctl disable --now nvgetty
sudo systemctl disable --now serial-getty@ttyTHS0.service

# ② 40-pin 引脚的 pinmux 默认不是 UART，需配置后重启
sudo /opt/nvidia/jetson-io/jetson-io.py     # Configure 40-pin header → 对应脚设为 uart
```

**硬件级确证**（TX/RX 短接后自发自收）：

```bash
sudo stty -F /dev/ttyTHS1 921600 raw -echo
sudo cat /dev/ttyTHS1 &
sudo sh -c 'echo hello-uart > /dev/ttyTHS1'   # 读端应打印 hello-uart
kill %1
```

**确定设备名后接入工程**（推荐直接改默认值）：

```bash
FCU_URL=/dev/ttyTHS1:921600 ./start_sensor.sh
# 或改 src/realflight_modules/px4ctrl/launch/mavros_px4.launch 的 fcu_url 默认值
```

> 波特率必须与飞控参数 `MAV_x_BAUD` 一致（接伴飞电脑的 TELEM 口通常 921600）。
> 换板子后这个值也要复核，不要沿用旧板子的配置。

**如果飞控不是走排针 UART**，Jetson 上还有更省事的两种接法：

```bash
FCU_URL=/dev/ttyACM0:57600            ./start_sensor.sh   # PX4 USB 口直连
FCU_URL=udp://:14540@127.0.0.1:14557  ./start_sensor.sh   # MAVLink over UDP（网口/WiFi）
```

> 为什么不用 `roslaunch mavros px4.launch`？因为上游默认 `fcu_url` 是 `/dev/ttyACM0:57600`（SITL/USB），连真机会出现「mavros 起来了但 `/mavros/*` 没有数据」。

#### 没有飞控/雷达时怎么测试

`start_sensor.sh` 把「飞控 + 雷达」绑在一起，两样都没有时别用它。注意 **`roslaunch mavros` 会自己起一个 roscore**，
mavros 一死就把 master 带走，后续 `roslaunch` 会报 `Unable to register with master node` —— 那是连锁反应，不是新故障。
所以**先单独起 master**：

```bash
roscore &
source devel/setup.bash
roslaunch --nodes livox_ros_driver2 msg_MID360.launch      # 只解析，不起进程
roslaunch --nodes fast_lio mapping_mid360.launch
roslaunch --nodes exploration_manager exploration_real.launch
```

要真跑算法链，用 bag 回放（不需要雷达、不需要飞控）：

```bash
./loop_min.sh /path/to/your.bag        # 起 FAST-LIO + FUEL 并回放
```


### 2. 雷达网口静态 IP

Mid-360 出厂 IP `192.168.1.106`，要求主机侧为 `192.168.1.5`（见 `src/livox_ros_driver2/config/MID360_config.json`）：

```bash
ip -br link                            # 找到接雷达的网口名，例如 eth0 / end0

sudo tee /etc/netplan/60-livox.yaml >/dev/null <<'YAML'
network:
  version: 2
  ethernets:
    eth0:                              # ★ 换成实际网口名
      dhcp4: false
      addresses: [192.168.1.5/24]
YAML

sudo chmod 600 /etc/netplan/60-livox.yaml
sudo netplan apply
ping -c 2 192.168.1.106                # 通了才说明链路 OK
```

若雷达实际 IP 不是 `.106`，改 `MID360_config.json` 里的 `"ip"` 字段。

### 3. 机载算力裁剪

机载单板机上务必：

```bash
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

并且**不要**在机载机上开 RViz（`start_mapping.sh` 已固定 `rviz:=false`）；RViz 可以在地面站笔记本上通过 `ROS_MASTER_URI` 远程连过来。

### 4. 多个 OpenCV 版本共存（Jetson 常见）

Jetson 上经常同时有两套 OpenCV：apt 装的 **4.2** 和 JetPack / 自己编译的 **4.5.4**。而 ROS 的 `cv_bridge` 是按 4.2 编的，于是链接期会出现：

```
/usr/bin/ld: warning: libopencv_imgcodecs.so.4.2, needed by /opt/ros/noetic/lib/libcv_bridge.so,
                may conflict with libopencv_imgcodecs.so.4.5
```

先看清楚机器上到底有几套：

```bash
ls -d /usr/lib/cmake/opencv4 /usr/lib/aarch64-linux-gnu/cmake/opencv4 /usr/local/lib/cmake/opencv4 2>/dev/null
ls  /usr/lib/aarch64-linux-gnu/libopencv_core.so.* /usr/local/lib/libopencv_core.so.* 2>/dev/null
grep -m1 'CV_VERSION_STR' /usr/include/opencv4/opencv2/core/version.hpp 2>/dev/null
```

然后二选一：

**(a) 让本工作区统一到 apt 的 4.2**（与 `cv_bridge` 一致，最省事）：

```bash
cd ~/exploration_ws
catkin_make -DOpenCV_DIR=/usr/lib/aarch64-linux-gnu/cmake/opencv4
```

**(b) 让全系统统一到 4.5.4**（Jetson 官方推荐，但要重编 `cv_bridge`）：

```bash
mkdir -p ~/cvbridge_ws/src && cd ~/cvbridge_ws/src
git clone -b noetic https://github.com/ros-perception/vision_opencv.git
cd ~/cvbridge_ws && catkin_make -DOpenCV_DIR=<4.5.4 的 cmake 目录>
```

> 本工程真正用到 OpenCV 的地方只有 `plan_env/src/map_ros.cpp:59` 的 `new cv::Mat`（深度相机通路，真机用 `depth_topic=/no_depth` 并不使用），所以选 (a) 完全够用。

---

## 五、常见编译错误速查

| 报错 | 原因 | 解决 |
|---|---|---|
| `Could not find a package configuration file provided by "livox_ros_driver2"` | `livox_ros_driver2/package.xml` 缺失，catkin 没发现该包 | `cp src/livox_ros_driver2/package_ROS1.xml src/livox_ros_driver2/package.xml` |
| `Cannot find source file: .../Livox-SDK2/...` 或 `livox_ros_driver2_node` 链接失败 | `Livox-SDK2/` 目录缺失 | 见第二节 #2；`setup.sh` 会自动从上游拉取正确的 v1.4.3 |
| `error: 'LivoxLidarDoubleEchoRawPoint' was not declared` / `'kLivoxLidarTypeMid360s' was not declared`（编译 `pub_handler.cpp`） | 你用的 `Livox-SDK2` 版本过旧（< v1.4.0） | 删掉 `src/livox_ros_driver2/Livox-SDK2/` 后重跑 `bash setup.sh`，它会拉取 v1.4.3 |
| `/usr/bin/ld: .../devel/lib/libplan_env.so: undefined reference to 'cv::Mat::Mat()'`（链接 `offline_mapper` / `exploration_node` 时） | `plan_env` 用了 OpenCV（`map_ros.cpp:59` 的 `new cv::Mat`）却漏链 `${OpenCV_LIBS}`，导致 `libplan_env.so` 带悬空符号 | 已在 `plan_env/CMakeLists.txt` 补上 `${OpenCV_LIBS}`；若仍报，见下一行 |
| `/usr/bin/ld: warning: libopencv_imgcodecs.so.4.2 ... may conflict with libopencv_imgcodecs.so.4.5` | 机器上同时存在两个 OpenCV（Jetson 常见：apt 的 4.2 + JetPack/自编译的 4.5），而 ROS 的 `cv_bridge` 是按 4.2 编的 | 让本工作区统一到同一个 OpenCV，或重编 `cv_bridge`（见第四节 4） |
| `内置 NLopt 源码缺失：.../bspline_opt/thirdparty/nlopt/CMakeLists.txt` | clone/拷贝不完整，vendored 依赖目录没带过来 | 确认 `src/fuel_planner/bspline_opt/thirdparty/nlopt/` 存在；若是 `git clone`，检查是否用了 `--filter`/浅克隆把该目录漏掉 |
| `内置 NLopt configure/编译失败` | 内置源码编译出错，CMake 会把完整输出打出来 | 按输出排查；也可 `catkin_make -DBSplineOpt_USE_BUNDLED_NLOPT=OFF` 改用系统 NLopt（`sudo apt install libnlopt-dev`） |
| `fatal error: nlopt.hpp: 没有那个文件或目录`（老版本才出现） | 旧版 `bspline_opt/CMakeLists.txt` 把 NLopt 写死为 `/usr/local`，而该路径没有 NLopt | 升级到含内置 NLopt 的版本；旧版可临时 `sudo apt install libnlopt-dev` 后把那两行 `set(NLOPT_*)` 改成系统路径 |
| `RLException: multiple files named [msg_MID360.launch] in package [livox_ros_driver2]`（同时列出 `launch/` 与 `launch_ROS1/` 两个路径） | `livox_ros_driver2` 里同时存在 `launch/` 和 `launch_ROS1/` 两份同名 launch。ROS1 的 `roslib` 遍历整个包目录，找到多个同名文件就报错 | 删掉多余的 `launch/`：`rm -rf src/livox_ros_driver2/launch`（保留上游的 `launch_ROS1/` 即可，roslaunch 能找到） |
| `[FATAL] FCU: DeviceError:serial:open: Input/output error` | 串口节点存在但背后没有可用的 UART。**注意这不是「没接飞控」**——UART 的 open 不需要对面有设备。常见于换板子后沿用了旧设备名（Jetson 真串口是 `/dev/ttyTHS*`，`/dev/ttyS*` 多为占位节点） | 见第四节 1：先用那段 python 探测脚本找出真正能 open 的 tty，Jetson 还要 `disable nvgetty` / 配 pinmux |
| `Unable to register with master node ... master may not be running yet` | 上一条的连锁反应：`roslaunch mavros` 自己起了 roscore，mavros 一死 master 就被关掉 | 测试时先单独 `roscore &`，再起其它节点 |
| `Could not find a package configuration file provided by "eigen_conversions"` | 缺 ROS 包 | `sudo apt install ros-noetic-eigen-conversions` |
| `fatal error: Python.h: No such file or directory`（编译 `fast_lio`） | 缺 python3 头文件（FAST_LIO 有 `find_package(PythonLibs REQUIRED)`） | `sudo apt install python3-dev` |
| `The dependency target "multi_map_server_generate_messages_cpp" ... does not exist` | 上游 `rviz_plugins` 遗留依赖，本仓库已移除该行 | 确认你的版本已包含该修复 |
| `does not contain a CMakeLists.txt file`（`livox_ros_driver` 目录） | v1 旧驱动的历史遗留副本 | 本仓库已加 `CATKIN_IGNORE` |
| `cannot find -larmadillo` | 缺 Armadillo（FUEL 仿真包需要） | `sudo apt install libarmadillo-dev` |
| `Resource not found: rviz` | 没装 `ros-noetic-rviz` | `sudo apt install ros-noetic-rviz` |

---

## 六、目录结构

```
exploration_ws/
├── setup.sh                       # ★ 一键环境配置 + 编译
├── .gitattributes                 # 强制 LF（避免 Windows 编辑后提交 CRLF 破坏 .sh）
├── start_sensor.sh                # ① MAVROS + Mid-360 驱动
├── start_mapping.sh               # ② FAST-LIO
├── start_run_ctrl.sh              # ③ px4ctrl 底层控制
├── start_takeoff.sh / start_land.sh   # ⑥⑦ 自动起降
├── start_planner.sh               # 历史遗留，真机不使用（见文件内注释）
├── HANDOVER_2026-09-06.md         # 真机调试交接文档（含已定位的三个问题）
├── offline_repro/                 # 0.05 m 分辨率复现实验日志
└── src/
    ├── fuel_planner/              # 探索与规划算法主体
    │   ├── plan_env/              # 概率占据栅格 + ESDF + 光线投射（含 offline_mapper）
    │   ├── active_perception/     # 前沿检测、视点采样、FOV 模型
    │   ├── exploration_manager/   # 探索状态机 + 分层规划器（真机入口 launch 在此）
    │   ├── plan_manage/           # 轨迹管理、B 样条轨迹服务器、安全门
    │   ├── bspline_opt/           # B 样条轨迹优化
    │   │   └── thirdparty/nlopt/  # ★ 内置 NLopt v2.7.1 源码（离线编译依赖用，MIT）
    │   ├── path_searching/        # 几何 A*、动力学 A*、拓扑路径
    │   └── poly_traj / bspline / traj_utils / utils/lkh_tsp_solver
    ├── realflight_modules/
    │   ├── mid360_fastlio/        # FAST-LIO（含内嵌 Livox 驱动副本，已 CATKIN_IGNORE）
    │   └── px4ctrl/               # 底层位置-姿态控制器（含自动起降、mavros_px4.launch）
    ├── livox_ros_driver2/         # ★ Livox 官方 ROS1 驱动 + 内置 Livox-SDK2 v1.4.3（离线依赖）
    ├── fuel_bridge/               # odom → PoseStamped 适配
    ├── waypoint_generator/        # 探索触发器
    ├── sim_* / utils/             # FUEL 上游自带的仿真与工具包（真机不使用）
    └── CMakeLists.txt
```

> 标 ★ 的两个 `thirdparty`/内置目录是**为了让工程可离线编译**而随仓库分发的第三方源码，
> 请勿删除；它们是 NLopt 与 Livox-SDK2 的唯一来源。

---

## 七、手工编译步骤（不想用 setup.sh 时）

```bash
# 1) 系统依赖
sudo apt update
sudo apt install -y build-essential cmake git wget curl pkg-config lsb-release gnupg2 \
  libeigen3-dev libpcl-dev libopencv-dev libboost-all-dev libarmadillo-dev \
  libyaml-cpp-dev libusb-1.0-0-dev libapr1-dev libaprutil1-dev \
  qtbase5-dev python3-dev python3-pip

# 2) ROS Noetic
sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc \
  -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
http://packages.ros.org/ros/ubuntu $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/ros1.list
sudo apt update
sudo apt install -y ros-noetic-ros-base ros-noetic-catkin ros-noetic-cmake-modules \
  ros-noetic-rviz ros-noetic-rosbag ros-noetic-pcl-ros ros-noetic-cv-bridge \
  ros-noetic-image-transport ros-noetic-message-filters ros-noetic-tf ros-noetic-tf2-ros \
  ros-noetic-eigen-conversions ros-noetic-visualization-msgs \
  ros-noetic-dynamic-reconfigure ros-noetic-nodelet ros-noetic-mavros ros-noetic-mavros-extras
sudo /opt/ros/noetic/lib/mavros/install_geographiclib_datasets.sh

# 3) ★ NLopt —— 不需要你做任何事
#    bspline_opt/CMakeLists.txt 会先找系统里的 NLopt；找不到就用仓库内置源码
#    src/fuel_planner/bspline_opt/thirdparty/nlopt/ 现场编成静态库 libnlopt.a。
#    整个过程不联网，也不需要 sudo。
#    若想改用系统 NLopt（可选）：
#      sudo apt install libnlopt-dev && catkin_make -DBSplineOpt_USE_BUNDLED_NLOPT=OFF

# 4) 编译
cd ~/exploration_ws
source /opt/ros/noetic/setup.bash
catkin_make -j4
source devel/setup.bash
```

> 编译时会看到一行 `bspline_opt: 未使用系统 NLopt -> 改用仓库内置源码离线编译`，
> 随后内置 NLopt 会被编成静态库。这是预期行为。

---

## 八、参考

- FUEL: *Fuel: Fast UAV Exploration using Incremental Frontier Structure and Hierarchical Planning* (RA-L 2021)
- FAST-LIO: *Fast LiDAR-Inertial Odometry*
- Livox ROS Driver 2 / Livox-SDK2（官方仓库）
- 本工程真机调试记录与问题定位：`HANDOVER_2026-09-06.md`

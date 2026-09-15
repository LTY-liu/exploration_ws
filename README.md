注意事项：
1.雷达的ip可能会因为硬件的不同而需要修改（路径：F:\EXPO_WS\exploration_ws\src\livox_ros_driver2\config\MID360s_config.json）
2.连接飞控的串口可能需要稍微修改一下，我们的香橙派是ttyS1，如果是nx可能需改成ttyACMx




启动流程：
工作空间下分别运行
启动雷达：
./start_sensor.sh
./start_mapping.sh
rostopic echo /Odom_high_freq

启动动力套
./start_run_ctrl.sh

启动规划（这一步的launch文件需要提前根据地图大小修改map_x\y\z和box_x\y\z还有init_x\y\z参数，map为建图大小，box为飞行&探索区域范围,init为起始时无人机所在位置）
source ./devel/setup.bash
roslaunch exploration_manager exploration_real.launch

启动rviz
source ./devel/setup.bash
roslaunch exploration_manager rviz.launch

录包：
rosbag record \
/Odom_high_freq \
/map_ros/pose \
/cloud_registered

起飞：（到达设定悬停点后会自动开始任务（0.6米悬停））
./start_takeoff.sh

完成任务后在exploration_real.launch终端ctrl+c然后降落
./start_land.sh





后期建图：
roslaunch plan_env offline_mapping.launch
roslaunch exploration_manager rviz.launch
rosbag play xxx.bag

#include <ros/ros.h>
#include <plan_env/sdf_map.h>

int main(int argc, char** argv) {
  ros::init(argc, argv, "offline_mapper");
  ros::NodeHandle nh("~");            // 私有句柄：所有参数从 ~/sdf_map/* ~/map_ros/* 读

  fast_planner::SDFMap map;           // SDFMap 内部持有 MapROS
  map.initMap(nh);                    // 读参数、分配体素、订阅/发布/timer 全在这

  ROS_INFO("[offline_mapper] waiting for /map_ros/cloud + /map_ros/pose ...");
  ros::spin();                        // 等 bag 重放的 cloud+pose 成对进来 → 自动建图
  return 0;
}
#include <ros/ros.h>
#include <geometry_msgs/PoseStamped.h>
#include <nav_msgs/Odometry.h>

ros::Publisher pose_pub;

void cb(const nav_msgs::OdometryConstPtr& odom) {
  geometry_msgs::PoseStamped pose;
  pose.header = odom->header;   // 关键:时间戳直接用 odom 的,才能和点云对上同步窗
  pose.pose   = odom->pose.pose;
  pose_pub.publish(pose);
}

int main(int argc, char** argv) {
  ros::init(argc, argv, "odom_to_pose");
  ros::NodeHandle nh("~");
  ros::Subscriber sub = nh.subscribe("odom", 50, cb);       // 入口(launch 里指向 /Odom_high_freq)
  pose_pub = nh.advertise<geometry_msgs::PoseStamped>("pose", 25);  // 出口(指向 /map_ros/pose)
  ros::spin();
}
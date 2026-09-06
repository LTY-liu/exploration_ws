#ifndef _PERCEPTION_UTILS_H_
#define _PERCEPTION_UTILS_H_

#include <ros/ros.h>

#include <Eigen/Eigen>

#include <cmath>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

using Eigen::Vector3d;
using std::shared_ptr;
using std::unique_ptr;
using std::vector;

namespace fast_planner {
class PerceptionUtils {
public:
  PerceptionUtils(ros::NodeHandle& nh);
  ~PerceptionUtils() {
  }
  // Set position and yaw
  void setPose(const Vector3d& pos, const double& yaw);

  // Get info of current pose
  void getFOV(vector<Vector3d>& list1, vector<Vector3d>& list2);
  bool insideFOV(const Vector3d& point);
  void getFOVBoundingBox(Vector3d& bmin, Vector3d& bmax);

private:
  enum class FOVType { PINHOLE, OMNI_LIDAR };

  // Data
  // Current sensor position and body yaw
  Vector3d pos_;
  double yaw_;
  Eigen::Matrix3d R_wb_;
  // Camera plane's normals in world frame
  vector<Vector3d> normals_;

  /* Params */
  FOVType fov_type_;
  std::string fov_type_name_;
  // Sensing range of pinhole camera
  double left_angle_, right_angle_, top_angle_, max_dist_, vis_dist_;
  // Native elevation limits of omni lidar, in its own frame
  double vertical_min_, vertical_max_;
  // Rotation from sensor frame to body/IMU frame
  Eigen::Matrix3d R_bs_;
  // Normal vectors of camera FOV planes in camera frame
  Vector3d n_top_, n_bottom_, n_left_, n_right_;
  // Transform between camera and body
  Eigen::Matrix4d T_cb_, T_bc_;
  // FOV visualization line segments in body frame
  vector<Vector3d> fov_vertices1_, fov_vertices2_;
};

}  // namespace fast_planner
#endif

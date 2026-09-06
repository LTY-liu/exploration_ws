#include <active_perception/perception_utils.h>

#include <pcl/filters/voxel_grid.h>

namespace fast_planner {
PerceptionUtils::PerceptionUtils(ros::NodeHandle& nh) {
  pos_.setZero();
  yaw_ = 0.0;
  R_wb_.setIdentity();

  nh.param("perception_utils/fov_type", fov_type_name_, std::string("pinhole"));
  nh.param("perception_utils/top_angle", top_angle_, -1.0);
  nh.param("perception_utils/left_angle", left_angle_, -1.0);
  nh.param("perception_utils/right_angle", right_angle_, -1.0);
  nh.param("perception_utils/max_dist", max_dist_, -1.0);
  nh.param("perception_utils/vis_dist", vis_dist_, -1.0);
  nh.param("perception_utils/vertical_min", vertical_min_, -7.0 * M_PI / 180.0);
  nh.param("perception_utils/vertical_max", vertical_max_, 52.0 * M_PI / 180.0);

  vector<double> sensor_to_body_R;
  nh.param("perception_utils/sensor_to_body_R", sensor_to_body_R,
           vector<double>{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0 });
  R_bs_.setIdentity();
  if (sensor_to_body_R.size() == 9) {
    for (int row = 0; row < 3; ++row)
      for (int col = 0; col < 3; ++col)
        R_bs_(row, col) = sensor_to_body_R[3 * row + col];
  } else {
    ROS_ERROR("perception_utils/sensor_to_body_R must contain 9 values; using identity.");
  }

  if (fov_type_name_ == "omni_lidar") {
    fov_type_ = FOVType::OMNI_LIDAR;
    if (vertical_min_ >= vertical_max_ || vertical_min_ < -M_PI_2 ||
        vertical_max_ > M_PI_2) {
      ROS_ERROR("Invalid omni lidar elevation limits; falling back to MID360 defaults [-7, 52] deg.");
      vertical_min_ = -7.0 * M_PI / 180.0;
      vertical_max_ = 52.0 * M_PI / 180.0;
    }
    const Eigen::Matrix3d orthogonality = R_bs_.transpose() * R_bs_;
    if (!orthogonality.isApprox(Eigen::Matrix3d::Identity(), 1e-2) ||
        std::abs(R_bs_.determinant() - 1.0) > 1e-2) {
      ROS_ERROR("perception_utils/sensor_to_body_R is not a rotation matrix; using identity.");
      R_bs_.setIdentity();
    }
  } else {
    if (fov_type_name_ != "pinhole")
      ROS_WARN("Unknown perception_utils/fov_type '%s'; using pinhole.", fov_type_name_.c_str());
    fov_type_name_ = "pinhole";
    fov_type_ = FOVType::PINHOLE;
  }

  n_top_ << 0.0, sin(M_PI_2 - top_angle_), cos(M_PI_2 - top_angle_);
  n_bottom_ << 0.0, -sin(M_PI_2 - top_angle_), cos(M_PI_2 - top_angle_);

  n_left_ << sin(M_PI_2 - left_angle_), 0.0, cos(M_PI_2 - left_angle_);
  n_right_ << -sin(M_PI_2 - right_angle_), 0.0, cos(M_PI_2 - right_angle_);
  T_cb_ << 0, -1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1;
  T_bc_ = T_cb_.inverse();

  if (fov_type_ == FOVType::PINHOLE) {
    // Pinhole FOV vertices in body frame.
    double hor = vis_dist_ * tan(left_angle_);
    double vert = vis_dist_ * tan(top_angle_);
    Vector3d origin(0, 0, 0);
    Vector3d left_up(vis_dist_, hor, vert);
    Vector3d left_down(vis_dist_, hor, -vert);
    Vector3d right_up(vis_dist_, -hor, vert);
    Vector3d right_down(vis_dist_, -hor, -vert);

    fov_vertices1_ = { origin, origin, origin, origin, left_up, right_up, right_down, left_down };
    fov_vertices2_ =
        { left_up, left_down, right_up, right_down, right_up, right_down, left_down, left_up };
  } else {
    // Draw the native 360-degree lidar elevation band and then rotate it into body frame.
    constexpr int kAzimuthSamples = 36;
    auto sensorPoint = [&](double azimuth, double elevation) {
      const double cos_elevation = cos(elevation);
      Vector3d point_sensor(vis_dist_ * cos_elevation * cos(azimuth),
                            vis_dist_ * cos_elevation * sin(azimuth),
                            vis_dist_ * sin(elevation));
      return R_bs_ * point_sensor;
    };
    for (int i = 0; i < kAzimuthSamples; ++i) {
      const double azimuth = 2.0 * M_PI * i / kAzimuthSamples;
      const double next_azimuth = 2.0 * M_PI * (i + 1) / kAzimuthSamples;
      const Vector3d lower = sensorPoint(azimuth, vertical_min_);
      const Vector3d upper = sensorPoint(azimuth, vertical_max_);
      fov_vertices1_.push_back(lower);
      fov_vertices2_.push_back(sensorPoint(next_azimuth, vertical_min_));
      fov_vertices1_.push_back(upper);
      fov_vertices2_.push_back(sensorPoint(next_azimuth, vertical_max_));
      if (i % 3 == 0) {
        fov_vertices1_.push_back(lower);
        fov_vertices2_.push_back(upper);
      }
    }
  }

  ROS_INFO("Perception FOV type: %s", fov_type_name_.c_str());
}

void PerceptionUtils::setPose(const Vector3d& pos, const double& yaw) {
  pos_ = pos;
  yaw_ = yaw;

  // Transform the normals of camera FOV
  R_wb_ << cos(yaw_), -sin(yaw_), 0.0, sin(yaw_), cos(yaw_), 0.0, 0.0, 0.0, 1.0;
  if (fov_type_ == FOVType::OMNI_LIDAR) {
    normals_.clear();
    return;
  }
  Vector3d pc = pos_;

  Eigen::Matrix4d T_wb = Eigen::Matrix4d::Identity();
  T_wb.block<3, 3>(0, 0) = R_wb_;
  T_wb.block<3, 1>(0, 3) = pc;
  Eigen::Matrix4d T_wc = T_wb * T_bc_;
  Eigen::Matrix3d R_wc = T_wc.block<3, 3>(0, 0);
  // Vector3d t_wc = T_wc.block<3, 1>(0, 3);
  normals_ = { n_top_, n_bottom_, n_left_, n_right_ };
  for (auto& n : normals_)
    n = R_wc * n;
}

void PerceptionUtils::getFOV(vector<Vector3d>& list1, vector<Vector3d>& list2) {
  list1.clear();
  list2.clear();

  // Get info for visualizing FOV at (pos, yaw)
  for (size_t i = 0; i < fov_vertices1_.size(); ++i) {
    auto p1 = R_wb_ * fov_vertices1_[i] + pos_;
    auto p2 = R_wb_ * fov_vertices2_[i] + pos_;
    list1.push_back(p1);
    list2.push_back(p2);
  }
}

bool PerceptionUtils::insideFOV(const Vector3d& point) {
  Eigen::Vector3d dir = point - pos_;
  const double distance = dir.norm();
  if (distance > max_dist_) return false;
  if (distance < 1e-6) return true;

  dir.normalize();
  if (fov_type_ == FOVType::OMNI_LIDAR) {
    // The map point is already in the world frame. Only transform its direction back into
    // the native lidar frame for visibility testing; do not transform /cloud_registered again.
    const Vector3d dir_body = R_wb_.transpose() * dir;
    const Vector3d dir_sensor = R_bs_.transpose() * dir_body;
    const double elevation =
        std::atan2(dir_sensor.z(), std::hypot(dir_sensor.x(), dir_sensor.y()));
    return elevation >= vertical_min_ && elevation <= vertical_max_;
  }

  for (auto n : normals_) {
    if (dir.dot(n) < 0.0) return false;
  }
  return true;
}

void PerceptionUtils::getFOVBoundingBox(Vector3d& bmin, Vector3d& bmax) {
  if (fov_type_ == FOVType::OMNI_LIDAR) {
    const Vector3d radius = Vector3d::Constant(max_dist_);
    bmin = pos_ - radius;
    bmax = pos_ + radius;
    return;
  }

  double left = yaw_ + left_angle_;
  double right = yaw_ - right_angle_;
  Vector3d left_pt = pos_ + max_dist_ * Vector3d(cos(left), sin(left), 0);
  Vector3d right_pt = pos_ + max_dist_ * Vector3d(cos(right), sin(right), 0);
  vector<Vector3d> points = { left_pt, right_pt };
  if (left > 0 && right < 0)
    points.push_back(pos_ + max_dist_ * Vector3d(1, 0, 0));
  else if (left > M_PI_2 && right < M_PI_2)
    points.push_back(pos_ + max_dist_ * Vector3d(0, 1, 0));
  else if (left > -M_PI_2 && right < -M_PI_2)
    points.push_back(pos_ + max_dist_ * Vector3d(0, -1, 0));
  else if ((left > M_PI && right < M_PI) || (left > -M_PI && right < -M_PI))
    points.push_back(pos_ + max_dist_ * Vector3d(-1, 0, 0));

  bmax = bmin = pos_;
  for (auto p : points) {
    bmax = bmax.array().max(p.array());
    bmin = bmin.array().min(p.array());
  }
}

}  // namespace fast_planner

cmake_minimum_required(VERSION 2.8.3)
project(plan_env)

set(CMAKE_BUILD_TYPE "Release")
set(CMAKE_CXX_FLAGS "-std=c++11")
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -Wall")

find_package(OpenCV REQUIRED)


find_package(catkin REQUIRED COMPONENTS
  roscpp
  rospy
  std_msgs
  visualization_msgs
  cv_bridge
  message_filters
)

find_package(Eigen3 REQUIRED)
find_package(PCL 1.7 REQUIRED)

catkin_package(
 INCLUDE_DIRS include
 LIBRARIES plan_env
 CATKIN_DEPENDS roscpp std_msgs
#  DEPENDS system_lib
)

include_directories( 
    SYSTEM 
    include 
    ${catkin_INCLUDE_DIRS}
    ${Eigen3_INCLUDE_DIRS} 
    ${PCL_INCLUDE_DIRS}
    ${OpenCV_INCLUDE_DIRS}
)

link_directories(${PCL_LIBRARY_DIRS})


add_library( plan_env 
    src/sdf_map.cpp 
    src/obj_predictor.cpp 
    src/edt_environment.cpp 
    src/raycast.cpp
    src/map_ros.cpp
    )
# ★ 必须显式链接 OpenCV：
#   map_ros.cpp:59 有 `depth_image_.reset(new cv::Mat);`，即需要 cv::Mat::Mat() 符号；
#   map_ros.h 通过 <cv_bridge/cv_bridge.h> 间接引入 OpenCV 头文件。
#   原来这里只链了 ${catkin_LIBRARIES} 和 ${PCL_LIBRARIES}，没有 ${OpenCV_LIBS}，
#   于是 libplan_env.so 会带着"未定义的 cv::Mat::Mat()"被生成；
#   在只有单一 OpenCV 的机器上可能靠 PCL/cv_bridge 的 DT_NEEDED 侥幸解析成功，
#   但在装有多个 OpenCV 版本（例如 Jetson 上 4.2 与 4.5 并存）的机器上，
#   链接 offline_mapper / exploration_node 时必然报：
#       /usr/bin/ld: libplan_env.so: undefined reference to `cv::Mat::Mat()'
#   这里与 sim_local_sensing/CMakeLists.txt 的写法保持一致。
target_link_libraries( plan_env
    ${catkin_LIBRARIES} 
    ${OpenCV_LIBS}
    ${PCL_LIBRARIES}
    )  

add_executable(obj_generator
    src/obj_generator.cpp 
    )
target_link_libraries(obj_generator 
    ${catkin_LIBRARIES})

add_executable(offline_mapper
    src/offline_mapper.cpp
    )
target_link_libraries(offline_mapper
    plan_env
    ${catkin_LIBRARIES}
    ${OpenCV_LIBS}
    ${PCL_LIBRARIES}
    )
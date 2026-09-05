cmake_minimum_required(VERSION 3.0)

project(livox_ros_driver2 VERSION 1.2.7 LANGUAGES CXX)
message(STATUS "livox_ros_driver2 version: ${PROJECT_VERSION}")

add_definitions(-DBUILDING_ROS1)

find_package(Boost 1.54 REQUIRED COMPONENTS
  system
  thread
  chrono
)

find_package(catkin REQUIRED COMPONENTS
  roscpp
  rospy
  sensor_msgs
  std_msgs
  message_generation
  rosbag
  pcl_ros
)

find_package(PCL REQUIRED)

add_message_files(FILES
  CustomPoint.msg
  CustomMsg.msg
)
generate_messages(DEPENDENCIES std_msgs)

find_package(PkgConfig)
pkg_check_modules(APR apr-1)

catkin_package(CATKIN_DEPENDS
  roscpp rospy std_msgs sensor_msgs pcl_ros
  message_runtime
)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Choose Release or Debug" FORCE)
endif()

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# -------- 编译 Livox-SDK2(静态库,内含 Mid-360S 支持)--------
file(MAKE_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/Livox-SDK2/build)
execute_process(COMMAND cmake .. WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/Livox-SDK2/build OUTPUT_VARIABLE cmd_res)
foreach(res ${cmd_res})
    message(${res})
endforeach()
execute_process(COMMAND make -j4 WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/Livox-SDK2/build OUTPUT_VARIABLE cmd_res)
foreach(res ${cmd_res})
    message(${res})
endforeach()

include_directories(
    ./
    ${CMAKE_CURRENT_SOURCE_DIR}/Livox-SDK2/sdk_core
    ${CMAKE_CURRENT_SOURCE_DIR}/Livox-SDK2/include
)

link_directories(
    ./
    ${CMAKE_CURRENT_SOURCE_DIR}/Livox-SDK2/build/sdk_core
)

link_directories(${PCL_LIBRARY_DIRS})
add_definitions(${PCL_DEFINITIONS})

add_executable(${PROJECT_NAME}_node
  ""
)

target_compile_options(${PROJECT_NAME}_node
  PRIVATE $<$<CXX_COMPILER_ID:GNU>:-Wall>
)

add_dependencies(${PROJECT_NAME}_node ${PROJECT_NAME}_generate_messages_cpp)

target_sources(${PROJECT_NAME}_node
  PRIVATE
  src/driver_node.cpp
  src/lds.cpp
  src/lds_lidar.cpp
  src/lddc.cpp
  src/livox_ros_driver2.cpp
  src/comm/comm.cpp
  src/comm/ldq.cpp
  src/comm/semaphore.cpp
  src/comm/lidar_imu_data_queue.cpp
  src/comm/cache_index.cpp
  src/comm/pub_handler.cpp
  src/parse_cfg_file/parse_cfg_file.cpp
  src/parse_cfg_file/parse_livox_lidar_cfg.cpp
  src/call_back/lidar_common_callback.cpp
  src/call_back/livox_lidar_callback.cpp
)

target_include_directories(${PROJECT_NAME}_node
  PUBLIC
  ${catkin_INCLUDE_DIRS}
  ${PCL_INCLUDE_DIRS}
  ${APR_INCLUDE_DIRS}
  3rdparty
  src
  src/include
)

target_link_libraries(${PROJECT_NAME}_node
  liblivox_lidar_sdk_static.a
  ${Boost_LIBRARY}
  ${catkin_LIBRARIES}
  ${PCL_LIBRARIES}
  ${APR_LIBRARIES}
)

install(TARGETS ${PROJECT_NAME}_node
  ARCHIVE DESTINATION ${CATKIN_PACKAGE_LIB_DESTINATION}
  LIBRARY DESTINATION ${CATKIN_PACKAGE_LIB_DESTINATION}
  RUNTIME DESTINATION ${CATKIN_PACKAGE_BIN_DESTINATION}
)

install(DIRECTORY launch_ROS1/
  DESTINATION ${CATKIN_PACKAGE_SHARE_DESTINATION}/launch_ROS1
)
install(DIRECTORY config/
  DESTINATION ${CATKIN_PACKAGE_SHARE_DESTINATION}/config
)
install(DIRECTORY msg/
  DESTINATION ${CATKIN_PACKAGE_SHARE_DESTINATION}/msg
)

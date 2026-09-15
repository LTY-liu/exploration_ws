cmake_minimum_required(VERSION 2.8.3)
project(bspline_opt)

set(CMAKE_BUILD_TYPE "Release")
set(CMAKE_CXX_FLAGS "-std=c++11")
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -Wall")

find_package(Eigen3 REQUIRED)
find_package(PCL 1.7 REQUIRED)

# ==============================================================================
# NLopt  ——  离线可用
#
# 本包需要 NLopt（头文件 nlopt.hpp + 库 libnlopt）。
#
# 原先这里把路径写死成：
#     set(NLOPT_INCLUDE_DIR "/usr/local/include")
#     set(NLOPT_LIBRARY     "/usr/local/lib/libnlopt.so")
# 带来三个问题：
#   1) 新机器必须先联网下载并编译 NLopt 才能编过本工程（不满足离线要求）；
#   2) apt 装的 libnlopt-dev 完全用不上（它装在 /usr/include 与
#      /usr/lib/<arch>-linux-gnu，不是 /usr/local）；
#   3) 缺依赖时的报错是
#        "没有规则可制作目标 /usr/local/lib/libnlopt.so"
#      / "fatal error: nlopt.hpp: 没有那个文件或目录"
#      完全看不出到底缺什么。
#
# 现在改成：先找系统里已安装的 NLopt；找不到就用**仓库内置源码**离线编译。
#   内置源码目录：thirdparty/nlopt   （NLopt v2.7.1，MIT 许可，随仓库一起分发）
#   => 源码下载下来之后，整机断网也能正常编译，构建过程不需要任何网络访问。
#
# 想强制使用内置版本（例如为了让所有人用完全一致的 NLopt 版本）：
#   catkin_make -DBSplineOpt_USE_BUNDLED_NLOPT=ON
# ==============================================================================
option(BSplineOpt_USE_BUNDLED_NLOPT
       "强制使用仓库内置的 NLopt（离线/版本一致），忽略系统已安装的 NLopt" OFF)

find_path(NLOPT_INCLUDE_DIR NAMES nlopt.hpp)
find_library(NLOPT_LIBRARY NAMES nlopt)

if(NOT BSplineOpt_USE_BUNDLED_NLOPT AND NLOPT_INCLUDE_DIR AND NLOPT_LIBRARY)
  message(STATUS "bspline_opt: 使用系统已安装的 NLopt -> ${NLOPT_LIBRARY}")
  set(NLOPT_EXTRA_LIBS "")
else()
  message(STATUS "bspline_opt: 未使用系统 NLopt -> 改用仓库内置源码离线编译")

  set(NLOPT_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/nlopt")
  set(NLOPT_BLD_DIR "${CMAKE_CURRENT_BINARY_DIR}/nlopt_build")

  if(NOT EXISTS "${NLOPT_SRC_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
      "内置 NLopt 源码缺失：${NLOPT_SRC_DIR}/CMakeLists.txt\n"
      "该目录随仓库分发，请确认 clone/拷贝完整（不需要联网下载）。")
  endif()

  # 说明：这里单独起一个 CMake 工程来编 NLopt，而不是 add_subdirectory，原因是
  #   1) -DBUILD_SHARED_LIBS=OFF 只作用于 NLopt 这一个工程，不会把 catkin 自己的
  #      动态库改成静态库（BUILD_SHARED_LIBS 是全局变量，add_subdirectory 会串味）；
  #   2) 命令行 -D 会直接写成 NLopt 自己的 cache 项，其内部的 option() 会沿用该值，
  #      不受 NLopt 的 cmake_minimum_required(3.2) 导致的 CMP0077 旧行为影响；
  #   3) 产出静态库 libnlopt.a，省掉 devel 空间里额外的 RPATH 依赖。
  # 同一模式在本仓库 livox_ros_driver2 中用于编译 Livox-SDK2，已在 arm64 上验证。
  file(MAKE_DIRECTORY "${NLOPT_BLD_DIR}")
  execute_process(
    COMMAND ${CMAKE_COMMAND} "${NLOPT_SRC_DIR}"
            -DCMAKE_BUILD_TYPE=Release
            -DBUILD_SHARED_LIBS=OFF
            -DNLOPT_CXX=ON
            -DNLOPT_PYTHON=OFF
            -DNLOPT_OCTAVE=OFF
            -DNLOPT_MATLAB=OFF
            -DNLOPT_GUILE=OFF
            -DNLOPT_SWIG=OFF
            -DNLOPT_TESTS=OFF
    WORKING_DIRECTORY "${NLOPT_BLD_DIR}"
    RESULT_VARIABLE _nlopt_cfg_rc
    OUTPUT_VARIABLE _nlopt_cfg_log
    ERROR_VARIABLE  _nlopt_cfg_log)
  if(NOT _nlopt_cfg_rc EQUAL 0)
    message(FATAL_ERROR "内置 NLopt configure 失败 (${_nlopt_cfg_rc})：\n${_nlopt_cfg_log}")
  endif()

  # 只编 nlopt 这一个目标（它会自动先生成 nlopt.hpp）
  execute_process(
    COMMAND ${CMAKE_COMMAND} --build . --target nlopt -- -j4
    WORKING_DIRECTORY "${NLOPT_BLD_DIR}"
    RESULT_VARIABLE _nlopt_bld_rc
    OUTPUT_VARIABLE _nlopt_bld_log
    ERROR_VARIABLE  _nlopt_bld_log)
  if(NOT _nlopt_bld_rc EQUAL 0)
    message(FATAL_ERROR "内置 NLopt 编译失败 (${_nlopt_bld_rc})：\n${_nlopt_bld_log}")
  endif()

  if(NOT EXISTS "${NLOPT_BLD_DIR}/libnlopt.a")
    message(FATAL_ERROR
      "内置 NLopt 编译结束，但没有找到静态库：${NLOPT_BLD_DIR}/libnlopt.a")
  endif()

  # nlopt.h  在源码目录 src/api/
  # nlopt.hpp 是构建期由 cmake/generate-cpp.cmake 从 src/api/nlopt-in.hpp 生成的，
  #           产物位于构建目录根下，所以两个目录都要进 include 路径。
  set(NLOPT_INCLUDE_DIR "${NLOPT_SRC_DIR}/src/api" "${NLOPT_BLD_DIR}")
  set(NLOPT_LIBRARY "${NLOPT_BLD_DIR}/libnlopt.a")
  # 静态库里不会带上 NLopt 自身的链接依赖，libm 需要显式补上
  set(NLOPT_EXTRA_LIBS m)
  message(STATUS "bspline_opt: 内置 NLopt 就绪 -> ${NLOPT_LIBRARY}")
endif()

find_package(catkin REQUIRED COMPONENTS
  roscpp
  rospy
  std_msgs
  visualization_msgs
  plan_env
  active_perception
  cv_bridge
)

catkin_package(
 INCLUDE_DIRS include
 LIBRARIES bspline_opt
 CATKIN_DEPENDS plan_env active_perception
)


include_directories( 
    SYSTEM 
    include 
    ${catkin_INCLUDE_DIRS}
    ${Eigen3_INCLUDE_DIRS} 
    ${PCL_INCLUDE_DIRS}
    ${NLOPT_INCLUDE_DIR}  
)

add_library( bspline_opt 
    src/bspline_optimizer.cpp 
    )
target_link_libraries( bspline_opt
    ${catkin_LIBRARIES} 
    ${NLOPT_LIBRARY}   
    ${NLOPT_EXTRA_LIBS}
    )

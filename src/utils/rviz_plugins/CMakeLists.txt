cmake_minimum_required(VERSION 2.8.3)
project(rviz_plugins)

add_compile_options(-std=c++11)

find_package(catkin REQUIRED COMPONENTS
  roscpp
  rviz
  quadrotor_msgs
)

catkin_package(
#  INCLUDE_DIRS include
#  LIBRARIES irobot_msgs
  DEPENDS system_lib
          message_runtime
)

###########
## Build ##
###########

if(rviz_QT_VERSION VERSION_LESS "5")
  message(STATUS "Using Qt4 based on the rviz_QT_VERSION: ${rviz_QT_VERSION}")
  find_package(Qt4 ${rviz_QT_VERSION} EXACT REQUIRED QtCore QtGui)
  ## pull in all required include dirs, define QT_LIBRARIES, etc.
  include(${QT_USE_FILE})
  qt4_wrap_cpp(MOC_FILES
    src/goal_tool.h
  )

else()
  message(STATUS "Using Qt5 based on the rviz_QT_VERSION: ${rviz_QT_VERSION}")
  find_package(Qt5 ${rviz_QT_VERSION} EXACT REQUIRED Core Widgets)
  ## make target_link_libraries(${QT_LIBRARIES}) pull in all required dependencies
  set(QT_LIBRARIES Qt5::Widgets)
  qt5_wrap_cpp(MOC_FILES
    src/goal_tool.h
  )
endif()

## I prefer the Qt signals and slots to avoid defining "emit", "slots",
## etc because they can conflict with boost signals, so define QT_NO_KEYWORDS here.
add_definitions(-DQT_NO_KEYWORDS)

## Here we specify which header files need to be run through "moc",
## Qt's meta-object compiler.

## Here we specify the list of source files, including the output of
## the previous command which is stored in ``${MOC_FILES}``.
set(SOURCE_FILES
  src/pose_tool.cpp
  src/goal_tool.cpp
  ${MOC_FILES}
)

## Specify additional locations of header files
## Your package locations should be listed before other locations
include_directories(include)
include_directories(
  ${catkin_INCLUDE_DIRS}
)

add_library(${PROJECT_NAME} ${SOURCE_FILES})

# 说明（2026 迁移修复）：原为本行 `add_dependencies(${PROJECT_NAME}
# multi_map_server_generate_messages_cpp)`，但 multi_map_server 并不在本工作区内，
# 会导致 CMake generate 阶段直接报错 "The dependency target
# multi_map_server_generate_messages_cpp ... does not exist"，使整个工作区无法编译。
# 已确认本包源码（src/*.cpp|*.h）不 include、也不链接 multi_map_server 的任何内容，
# 该依赖纯属上游遗留，故删除。若将来确实需要该包，请把 multi_map_server 加回工作区。

target_link_libraries(${PROJECT_NAME}
    ${catkin_LIBRARIES}
    ${QT_LIBRARIES}
    )
install(TARGETS
  ${PROJECT_NAME}
  ARCHIVE DESTINATION ${CATKIN_PACKAGE_LIB_DESTINATION}
  LIBRARY DESTINATION ${CATKIN_PACKAGE_LIB_DESTINATION}
  RUNTIME DESTINATION ${CATKIN_PACKAGE_BIN_DESTINATION}
)

install(FILES
  plugin_description.xml
  DESTINATION ${CATKIN_PACKAGE_SHARE_DESTINATION})

install(DIRECTORY media/
  DESTINATION ${CATKIN_PACKAGE_SHARE_DESTINATION}/media)

install(DIRECTORY icons/
  DESTINATION ${CATKIN_PACKAGE_SHARE_DESTINATION}/icons)

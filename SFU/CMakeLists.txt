cmake_minimum_required(VERSION 3.10)
project(sfu_server CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(sfu_server main.cpp protocol.h)

if(WIN32)
    target_link_libraries(sfu_server ws2_32)
else()
    target_link_libraries(sfu_server pthread)
endif()

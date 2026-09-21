cmake_minimum_required(VERSION 3.10)
project(audio_core CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(audio_core SHARED 
    audio_core.cpp 
    audio_core.h
    protocol.h
)

if(WIN32)
    set_target_properties(audio_core PROPERTIES
        COMPILE_DEFINITIONS "BUILD_DLL;NOMINMAX;WIN32_LEAN_AND_MEAN;_CRT_SECURE_NO_WARNINGS"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
    )
    target_link_libraries(audio_core ws2_32)
elseif(APPLE)
    find_library(COREAUDIO_LIB CoreAudio REQUIRED)
    find_library(AUDIOTOOLBOX_LIB AudioToolbox REQUIRED)
    find_library(COREFOUNDATION_LIB CoreFoundation REQUIRED)
    target_link_libraries(audio_core ${COREAUDIO_LIB} ${AUDIOTOOLBOX_LIB} ${COREFOUNDATION_LIB} pthread)
    set_target_properties(audio_core PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
    )
else()
    target_link_libraries(audio_core pthread dl m)
    set_target_properties(audio_core PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
    )
endif()
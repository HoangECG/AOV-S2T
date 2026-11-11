cmake_minimum_required(VERSION 3.21)
project(live_subtitle_worker LANGUAGES CXX)

set(WHISPER_CPP_SOURCE_DIR "" CACHE PATH "Pinned whisper.cpp checkout")
set(WORKER_BACKEND "" CACHE STRING "Worker backend identity")
set(WORKER_BUILD_ID "" CACHE STRING "Immutable worker build identity")
set(WORKER_MODEL_REVISION "" CACHE STRING "Compatible model revision")

if(NOT EXISTS "${WHISPER_CPP_SOURCE_DIR}/CMakeLists.txt")
  message(FATAL_ERROR "WHISPER_CPP_SOURCE_DIR must point to the pinned whisper.cpp checkout")
endif()
foreach(required WORKER_BACKEND WORKER_BUILD_ID WORKER_MODEL_REVISION)
  if("${${required}}" STREQUAL "")
    message(FATAL_ERROR "${required} is required")
  endif()
endforeach()

set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
add_subdirectory("${WHISPER_CPP_SOURCE_DIR}" whispercpp EXCLUDE_FROM_ALL)

add_executable(live-subtitle-worker src/worker_main.cpp)
target_compile_features(live-subtitle-worker PRIVATE cxx_std_17)
target_include_directories(live-subtitle-worker PRIVATE "${WHISPER_CPP_SOURCE_DIR}/include")
target_link_libraries(live-subtitle-worker PRIVATE whisper)
target_compile_definitions(live-subtitle-worker PRIVATE
  WORKER_BACKEND="${WORKER_BACKEND}"
  WORKER_BUILD_ID="${WORKER_BUILD_ID}"
  WORKER_MODEL_REVISION="${WORKER_MODEL_REVISION}")
set_target_properties(live-subtitle-worker PROPERTIES OUTPUT_NAME "worker-${WORKER_BACKEND}")

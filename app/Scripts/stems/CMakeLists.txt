# demucs.cpp as a static archive the app links (stem separation design §2).
#
# The library's own CMakeLists builds its command-line drivers as well, against vendored
# libnyquist and with `-march=native`; this one builds the inference sources alone, for arm64,
# with Eigen over Accelerate's BLAS and without OpenMP (Apple's clang has none; the pragmas are
# ignored).
cmake_minimum_required(VERSION 3.20)
project(neuralsheet_stems CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG -DEIGEN_USE_BLAS -Wno-unknown-pragmas -Wno-deprecated-declarations")

set(DEMUCS_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../ThirdParty/demucs.cpp")

if(NOT EXISTS "${DEMUCS_ROOT}/vendor/eigen/Eigen/Dense")
    message(FATAL_ERROR "Eigen is missing under ${DEMUCS_ROOT}/vendor/eigen; run git submodule update --init --recursive")
endif()

file(GLOB DEMUCS_SOURCES "${DEMUCS_ROOT}/src/*.cpp")

add_library(demucs STATIC ${DEMUCS_SOURCES})
target_include_directories(demucs PUBLIC "${DEMUCS_ROOT}/vendor/eigen" "${DEMUCS_ROOT}/src")

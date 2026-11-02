cmake_minimum_required(VERSION 3.16)

project(treeTests LANGUAGES CXX)

enable_testing()

find_package(Qt6 REQUIRED COMPONENTS Test)

set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CLADESCOPE_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../.." CACHE PATH
    "Directory containing tree.cpp and tree.h")

add_executable(tree
    tst_tree.cpp
    ${CLADESCOPE_SRC_DIR}/tree.cpp
    ${CLADESCOPE_SRC_DIR}/tree.h
)

target_include_directories(tree PRIVATE ${CLADESCOPE_SRC_DIR})

target_compile_definitions(tree PRIVATE
    FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../data")

target_link_libraries(tree PRIVATE
    Qt6::Core
    Qt6::Test
)

add_test(NAME tree COMMAND tree)
set_tests_properties(tree PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 300)

include(GNUInstallDirs)
install(TARGETS tree
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
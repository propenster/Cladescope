cmake_minimum_required(VERSION 3.16)

project(cladescope VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Quick Svg)

qt_standard_project_setup(REQUIRES 6.10)

# Content of downloaded design from Figma to Qt or similar
if (EXISTS "${CMAKE_CURRENT_LIST_DIR}/importedcontent/CMakeLists.txt")
    add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/importedcontent)
endif()

if(WIN32)
    set(app_icon_windows "${CMAKE_CURRENT_SOURCE_DIR}/packaging/cladescope.rc")
endif()

qt_add_executable(cladescope
    main.cpp
    ${app_icon_windows}
)

qt_add_qml_module(cladescope
    URI cladescope
    QML_FILES
        Main.qml
        TopBar.qml
        TopBars.qml
        MenuButton.qml
        TreeViewer.qml
        Sidebar.qml
        TreeCanvas.qml
        StatusToast.qml
    SOURCES
        tree.h
        tree.cpp
        appbridge.h
        appbridge.cpp
    RESOURCES
        resources.qrc
)

qt_add_resources(cladescope "app_icons"
    PREFIX "/icons"
    BASE   "${CMAKE_CURRENT_SOURCE_DIR}/ui/assets/icons"
    FILES
        ui/assets/icons/cladescope-C-16.png
        ui/assets/icons/cladescope-C-32.png
        ui/assets/icons/cladescope-C-48.png
        ui/assets/icons/cladescope-C-64.png
        ui/assets/icons/cladescope-C-128.png
        ui/assets/icons/cladescope-C-256.png
        ui/assets/icons/cladescope-C-512.png
    )
# Qt for iOS sets MACOSX_BUNDLE_GUI_IDENTIFIER automatically since Qt 6.1.
# If you are developing for iOS or macOS you should consider setting an
# explicit, fixed bundle identifier manually though.
set_target_properties(cladescope PROPERTIES
#    MACOSX_BUNDLE_GUI_IDENTIFIER com.example.cladescope
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

target_link_libraries(cladescope
    PRIVATE Qt6::Quick
    Qt6::Svg
)

install(TARGETS cladescope
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

option(CLADESCOPE_BUILD_TESTS "Build unit tests" ON)
if(CLADESCOPE_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests/cpp)
endif()
cmake_minimum_required(VERSION 3.15)
project(JoyCon2Mac)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0")

# Require Xcode generator if we are building the driverkit extension
if(NOT CMAKE_GENERATOR STREQUAL "Xcode")
    message(WARNING "Building DriverKit requires the Xcode generator (cmake -G Xcode). The driver target will not be built.")
endif()

# Enable Objective-C++ support
enable_language(OBJCXX)

# Global Xcode settings
set(CMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH "YES")
set(CMAKE_XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES")

# ----------------------------------------------------
# Target: VirtualJoyConDriver (DriverKit Extension)
# ----------------------------------------------------
if(CMAKE_GENERATOR STREQUAL "Xcode")
    set_source_files_properties(
        VirtualJoyConDriver/VirtualJoyConDriver.iig
        PROPERTIES
        XCODE_EXPLICIT_FILE_TYPE "sourcecode.iig"
    )

    add_library(VirtualJoyConDriver MODULE
        VirtualJoyConDriver/VirtualJoyConDriver.cpp
        VirtualJoyConDriver/VirtualJoyConDriver.iig
        ${CMAKE_CURRENT_SOURCE_DIR}/build/generated/VirtualJoyConDriver.iig.cpp
    )

    target_include_directories(VirtualJoyConDriver PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/build/generated
    )

    target_link_libraries(VirtualJoyConDriver
        "-framework DriverKit"
        "-framework HIDDriverKit"
    )

    set_target_properties(VirtualJoyConDriver PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
        XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
        XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
        XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/VirtualJoyConDriver/VirtualJoyConDriver.entitlements"
        XCODE_ATTRIBUTE_WRAPPER_EXTENSION "dext"
        XCODE_ATTRIBUTE_MACH_O_TYPE "mh_execute"
        XCODE_ATTRIBUTE_SDKROOT "driverkit"
        XCODE_ATTRIBUTE_USER_HEADER_SEARCH_PATHS "$(inherited) $(DERIVED_SOURCES_DIR)"
        XCODE_ATTRIBUTE_LIBRARY_SEARCH_PATHS "$(inherited) $(SDKROOT)/System/DriverKit/usr/lib"
        XCODE_ATTRIBUTE_GENERATE_INFOPLIST_FILE "YES"
        XCODE_ATTRIBUTE_INFOPLIST_KEY_CFBundleIdentifier "com.virtualjoycondriver"
        XCODE_ATTRIBUTE_INFOPLIST_KEY_IOKitPersonalities "
            <dict>
                <key>VirtualJoyConDriver</key>
                <dict>
                    <key>CFBundleIdentifier</key>
                    <string>com.virtualjoycondriver</string>
                    <key>IOClass</key>
                    <string>IOUserService</string>
                    <key>IOMatchCategory</key>
                    <string>VirtualJoyConDriver</string>
                    <key>IOProviderClass</key>
                    <string>IOUserResources</string>
                    <key>IOResourceMatch</key>
                    <string>IOKit</string>
                    <key>IOUserClass</key>
                    <string>VirtualJoyConDriver</string>
                    <key>IOUserServerName</key>
                    <string>com.virtualjoycondriver</string>
                    <key>bConfigurationValue</key>
                    <integer>1</integer>
                    <key>bInterfaceNumber</key>
                    <integer>0</integer>
                    <key>idProduct</key>
                    <integer>8192</integer>
                    <key>idVendor</key>
                    <integer>1363</integer>
                </dict>
            </dict>
        "
    )
endif()

# ----------------------------------------------------
# Target: joycon2mac (Daemon)
# ----------------------------------------------------
set(SOURCES
    JoyCon2Mac/main.mm
    JoyCon2Mac/BLEManager.mm
    JoyCon2Mac/JoyConDecoder.cpp
    JoyCon2Mac/PairingManager.mm
    JoyCon2Mac/DriverKitClient.mm
    JoyCon2Mac/MouseEmitter.mm
)

set_source_files_properties(
    JoyCon2Mac/main.mm
    JoyCon2Mac/BLEManager.mm
    JoyCon2Mac/PairingManager.mm
    JoyCon2Mac/DriverKitClient.mm
    JoyCon2Mac/MouseEmitter.mm
    PROPERTIES COMPILE_FLAGS "-fobjc-arc"
)

set(HEADERS
    JoyCon2Mac/BLEManager.h
    JoyCon2Mac/JoyConDecoder.h
    JoyCon2Mac/PairingManager.h
    JoyCon2Mac/DriverKitClient.h
    JoyCon2Mac/MouseEmitter.h
)

add_executable(joycon2mac ${SOURCES} ${HEADERS})

target_include_directories(joycon2mac PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/JoyCon2Mac
)

target_link_libraries(joycon2mac
    "-framework Foundation"
    "-framework CoreBluetooth"
    "-framework IOBluetooth"
    "-framework IOKit"
    "-framework ApplicationServices"
)

target_compile_options(joycon2mac PRIVATE
    -Wall
    -Wextra
    -Wno-unused-parameter
)

if(CMAKE_GENERATOR STREQUAL "Xcode")
    set_target_properties(joycon2mac PROPERTIES
        XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "-"
    )
endif()

set_target_properties(joycon2mac PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)

message(STATUS "Building JoyCon2Mac - Phases 1-5")
message(STATUS "  C++ Standard: ${CMAKE_CXX_STANDARD}")
message(STATUS "  macOS Target: ${CMAKE_OSX_DEPLOYMENT_TARGET}")
message(STATUS "  Build Type: ${CMAKE_BUILD_TYPE}")
message(STATUS "  Features: BLE + Pairing + HID Gamepad + Mouse + NFC")

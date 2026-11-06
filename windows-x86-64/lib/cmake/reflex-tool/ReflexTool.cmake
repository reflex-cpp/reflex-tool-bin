# Part of reflex-tool, under the Apache License 2.0.
# See https://www.apache.org/licenses/LICENSE-2.0.txt for license information.
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.25)

if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND NOT DEFINED CACHE{REFLEX_TOOL_GCC_INSTALL_DIR})
    message(STATUS "reflex-tool: detecting the GCC install directory")
    execute_process(
            COMMAND "${CMAKE_CXX_COMPILER}" -print-search-dirs
            OUTPUT_VARIABLE GCC_PRINT_SEARCH_DIRS_OUTPUT
            COMMAND_ERROR_IS_FATAL ANY)
    # Escape semicolons. Each list operation consume one baslash.
    string(REPLACE ";" "\\;" ESCAPED_GCC_PRINT_SEARCH_DIRS_OUTPUT "${GCC_PRINT_SEARCH_DIRS_OUTPUT}")
    string(REGEX REPLACE "[\r\n]+" ";" GCC_PRINT_SEARCH_DIRS_LINES "${ESCAPED_GCC_PRINT_SEARCH_DIRS_OUTPUT}")
    list(FILTER GCC_PRINT_SEARCH_DIRS_LINES INCLUDE REGEX "install: .+")
    list(LENGTH GCC_PRINT_SEARCH_DIRS_LINES INSTALL_DIR_LINE_COUNT)
    if (NOT INSTALL_DIR_LINE_COUNT EQUAL 1)
        message(FATAL_ERROR "reflex-tool: failed to detect the GCC install directory.\n"
                            "Could not find the \"install: ...\" line in the output of "
                            "\"${CMAKE_CXX_COMPILER} -print-search-dirs\".\n"
                            "The raw output is:\n"
                            "${GCC_PRINT_SEARCH_DIRS_OUTPUT}")
    endif ()
    string(REGEX MATCH "install: (.*)" REGEX_OUTPUT_VAR "${GCC_PRINT_SEARCH_DIRS_LINES}")
    if (NOT REGEX_OUTPUT_VAR)
        message(FATAL_ERROR "reflex-tool: failed to detect the GCC install directory.\n"
                            "Could not parse the \"install: ...\" line in the output of "
                            "\"${CMAKE_CXX_COMPILER} -print-search-dirs\".\n"
                            "The raw line is:\n"
                            "${GCC_PRINT_SEARCH_DIRS_LINES}")
    endif ()
    set(GCC_INSTALL_DIR "${CMAKE_MATCH_1}")
    if (NOT IS_DIRECTORY "${GCC_INSTALL_DIR}")
        message(FATAL_ERROR "reflex-tool: failed to detect the GCC install directory.\n"
                            "\"${GCC_INSTALL_DIR}\" is not a directory")
    endif ()
    message(STATUS "reflex-tool: using GCC install directory: ${GCC_INSTALL_DIR}")
    set(REFLEX_TOOL_GCC_INSTALL_DIR "${GCC_INSTALL_DIR}" CACHE PATH "")
    mark_as_advanced(REFLEX_TOOL_GCC_INSTALL_DIR)
endif ()

function(reflex_generate_metadata)
    if (NOT TARGET reflex::tool)
        message(FATAL_ERROR "The reflex::tool target doesn't exist when calling reflex_generate_metadata().\n"
                            "A call to find_package(reflex-tool) may be missing")
    endif ()

    set(options USE_INTERFACE_PROPERTIES)
    set(oneValueArgs TARGET HEADER OUTPUT DEPFILE)
    set(multiValueArgs EXTRA_COMPILE_DEFINITIONS)
    cmake_parse_arguments(REFLEX_TOOL_ARGS "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    set(USE_INTERFACE_PROPERTIES ${REFLEX_TOOL_ARGS_USE_INTERFACE_PROPERTIES})
    set(TARGET_NAME ${REFLEX_TOOL_ARGS_TARGET})
    set(METADATA_FILENAME ${REFLEX_TOOL_ARGS_OUTPUT})
    set(DEPFILE_PATH ${REFLEX_TOOL_ARGS_DEPFILE})
    set(EXTRA_COMPILE_DEFINITIONS ${REFLEX_TOOL_ARGS_EXTRA_COMPILE_DEFINITIONS})

    cmake_path(ABSOLUTE_PATH REFLEX_TOOL_ARGS_HEADER OUTPUT_VARIABLE HEADER_ABSOLUTE_PATH)

    set(BASE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${CMAKE_CXX_FLAGS_${CMAKE_BUILD_TYPE}}")
    separate_arguments(BASE_CXX_FLAGS NATIVE_COMMAND ${BASE_CXX_FLAGS})

    if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        list(FILTER BASE_CXX_FLAGS EXCLUDE REGEX "\-fcoroutines")
    endif ()

    list(TRANSFORM BASE_CXX_FLAGS PREPEND "--extra-arg=" OUTPUT_VARIABLE BASE_CXX_FLAGS)

    get_target_property(TARGET_CXX_STANDARD ${TARGET_NAME} CXX_STANDARD)
    if (NOT TARGET_CXX_STANDARD)
        message(FATAL_ERROR "reflex-tool: target ${TARGET_NAME} is missing the CXX_STANDARD property.\n"
                            "Check that CMAKE_CXX_STANDARD is set before the target is created.\n"
                            "For INTERFACE libraries with no source files the property may need to be set manually.")
    endif ()
    if (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC" OR CMAKE_CXX_SIMULATE_ID STREQUAL "MSVC")
        if (TARGET_CXX_STANDARD GREATER 23)
            set(EXTRA_CXX_FLAGS ${EXTRA_CXX_FLAGS} "--extra-arg=-std:c++latest")
        elseif (TARGET_CXX_STANDARD EQUAL 23)
            set(EXTRA_CXX_FLAGS ${EXTRA_CXX_FLAGS} "--extra-arg=-clang:-std=c++23")
        else ()
            set(EXTRA_CXX_FLAGS ${EXTRA_CXX_FLAGS} "--extra-arg=-std:c++${TARGET_CXX_STANDARD}")
        endif ()
    else ()
        set(EXTRA_CXX_FLAGS ${EXTRA_CXX_FLAGS} "--extra-arg=-std=c++${TARGET_CXX_STANDARD}")
    endif ()
    if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        # Tell Clang which GCC installation to use
        set(EXTRA_CXX_FLAGS "${EXTRA_CXX_FLAGS} --extra-arg=--gcc-install-dir=\"${REFLEX_TOOL_GCC_INSTALL_DIR}\"")
        if (TARGET_CXX_STANDARD GREATER 11)
            # GCC doesn't require such a flag but Clang does
            set(EXTRA_CXX_FLAGS ${EXTRA_CXX_FLAGS} --extra-arg=-fsized-deallocation)
        endif ()
    endif ()

    if (USE_INTERFACE_PROPERTIES)
        set(TARGET_ORIGINAL_OPTIONS $<TARGET_PROPERTY:${TARGET_NAME},INTERFACE_COMPILE_OPTIONS>)
        set(TARGET_COMPILE_OPTIONS "$<$<BOOL:${TARGET_ORIGINAL_OPTIONS}>:--extra-arg=$<JOIN:${TARGET_ORIGINAL_OPTIONS}, --extra-arg=>>")
        set(options ${BASE_CXX_FLAGS} ${EXTRA_CXX_FLAGS} ${TARGET_COMPILE_OPTIONS} --extra-arg=-Wno-everything)
        set(defines $<FILTER:$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:${TARGET_NAME},INTERFACE_COMPILE_DEFINITIONS>>,EXCLUDE,^$>)
        set(includes "$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:${TARGET_NAME},INTERFACE_INCLUDE_DIRECTORIES>>")
    else ()
        set(TARGET_ORIGINAL_OPTIONS $<TARGET_PROPERTY:${TARGET_NAME},COMPILE_OPTIONS>)
        set(TARGET_COMPILE_OPTIONS "$<$<BOOL:${TARGET_ORIGINAL_OPTIONS}>:--extra-arg=$<JOIN:${TARGET_ORIGINAL_OPTIONS}, --extra-arg=>>")
        set(options ${BASE_CXX_FLAGS} ${EXTRA_CXX_FLAGS} ${TARGET_COMPILE_OPTIONS} --extra-arg=-Wno-everything)
        set(defines  $<FILTER:$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:${TARGET_NAME},COMPILE_DEFINITIONS>>,EXCLUDE,^$>)
        set(includes "$<REMOVE_DUPLICATES:$<TARGET_PROPERTY:${TARGET_NAME},INCLUDE_DIRECTORIES>>")
    endif ()

    set(COMPILE_OPTIONS_DEFINITIONS "$<$<BOOL:${defines}>:--extra-arg=-D\"$<JOIN:${defines},\" --extra-arg=-D\">\">")

    set(EXTRA_COMPILE_DEFINITION_OPTIONS "")
    if (EXTRA_COMPILE_DEFINITIONS)
        list(TRANSFORM EXTRA_COMPILE_DEFINITIONS PREPEND "--extra-arg=-D\"" OUTPUT_VARIABLE EXTRA_COMPILE_DEFINITIONS_PRE)
        list(TRANSFORM EXTRA_COMPILE_DEFINITIONS_PRE APPEND "\"" OUTPUT_VARIABLE EXTRA_COMPILE_DEFINITION_OPTIONS)
    endif()

    set(COMPILE_OPTIONS_INCLUDES "$<$<BOOL:${includes}>:--extra-arg=-I\"$<JOIN:${includes},\" --extra-arg=-I\">\">")

    set(COMPILER_OPTIONS ${options} ${COMPILE_OPTIONS_DEFINITIONS} ${EXTRA_COMPILE_DEFINITION_OPTIONS} ${COMPILE_OPTIONS_INCLUDES})
    set(COMPILER_OPTIONS "$<JOIN:${COMPILER_OPTIONS}, >")

    if (CMAKE_CXX_SIMULATE_ID STREQUAL "MSVC" OR CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
        set(CLANG_DRIVER_MODE_FLAG "--extra-arg-before=--driver-mode=cl")
        set(ADDITIONAL_OPTIONS "--extra-arg=-clang:-MQ${METADATA_FILENAME} --extra-arg=/TP --extra-arg=-clang:-MD --extra-arg=-clang:-MF${DEPFILE_PATH}")
    else ()
        set(ADDITIONAL_OPTIONS "--extra-arg=-MQ${METADATA_FILENAME} --extra-arg-before=-xc++ --extra-arg=-MD --extra-arg=-MF${DEPFILE_PATH}")
    endif ()

    cmake_path(REPLACE_EXTENSION DEPFILE_PATH LAST_ONLY ".rsp" OUTPUT_VARIABLE RSP_PATH)
    set(RSP_CONTENT "${HEADER_ABSOLUTE_PATH} --metadata-filename \"${METADATA_FILENAME}\" ${ADDITIONAL_OPTIONS} ${CLANG_DRIVER_MODE_FLAG} ${COMPILER_OPTIONS}")

    # Setting the CONDITION to $<COMPILE_LANGUAGE:CXX> is required so that CMake doesn't attempt to generate the same
    # file for multiple languages. This is a problem when the content (e.g. compiler flags) is different different
    # languages.
    file(GENERATE OUTPUT ${RSP_PATH} CONTENT "${RSP_CONTENT}" CONDITION $<COMPILE_LANGUAGE:CXX>)
    add_custom_command(
            OUTPUT "${METADATA_FILENAME}"
            COMMAND reflex::tool @${RSP_PATH} --
            DEPENDS reflex::tool
            MAIN_DEPENDENCY "${HEADER_ABSOLUTE_PATH}"
            DEPFILE ${DEPFILE_PATH}
            COMMAND_EXPAND_LISTS)
endfunction()

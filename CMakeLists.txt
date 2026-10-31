############################################################################
# Copyright (c) 2025, xeus-lean contributors
#
# Distributed under the terms of the Apache Software License 2.0.
#
# The full license is in the file LICENSE, distributed with this software.
############################################################################

cmake_minimum_required(VERSION 3.10.0)
project(xeus-lean VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake;${CMAKE_MODULE_PATH}")

set(XEUS_LEAN_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/include)

include(GNUInstallDirs)

# ============================================================================
# EMSCRIPTEN (WASM) BUILD
# ============================================================================

if(EMSCRIPTEN)
    message(STATUS "Building xeus-lean for WASM (emscripten)")
    add_compile_definitions(XEUS_LEAN_EMSCRIPTEN_WASM_BUILD)

    # Clear macOS linker flags that leak from nix and break wasm-ld,
    # then set Memory64 flags. Use CMAKE_*_FLAGS (not add_compile_options)
    # so flags propagate to all FetchContent subdirectories (xeus, xeus-lite, etc.).
    # Lean's compacted region / .olean format is pointer-size dependent.
    set(CMAKE_C_FLAGS "-sMEMORY64")
    set(CMAKE_CXX_FLAGS "-sMEMORY64 -fwasm-exceptions")
    set(CMAKE_EXE_LINKER_FLAGS "-sMEMORY64")
    set(CMAKE_SHARED_LINKER_FLAGS "-sMEMORY64")
    set(CMAKE_MODULE_LINKER_FLAGS "-sMEMORY64")

    # Dependencies (from the emscripten-forge environment)
    # ==================================================

    find_package(nlohmann_json 3.11.3 REQUIRED)
    find_package(xeus 6.0 REQUIRED)
    find_package(xeus-lite REQUIRED)

    # Build libleanrt from lean4 source
    # ==================================

    include(LeanRtWasm)
    fetch_and_build_leanrt(LEANRT_LIB LEAN4_INCLUDE_DIR)

    # Build Lean stage0 stdlib + REPL as WASM static libs
    # ====================================================

    include(LeanStage0Wasm)
    build_lean_stage0_wasm(STAGE0_INIT_LIB STAGE0_STD_LIB STAGE0_LEAN_LIB STAGE0_REPL_LIB)

    # xeus-lean WASM static library
    # ==============================

    add_library(xeus-lean-static STATIC src/xinterpreter_wasm.cpp)

    target_include_directories(xeus-lean-static PUBLIC
        $<BUILD_INTERFACE:${XEUS_LEAN_INCLUDE_DIR}>
        $<INSTALL_INTERFACE:include>
    )

    target_link_libraries(xeus-lean-static
        PUBLIC xeus
        PUBLIC nlohmann_json::nlohmann_json
        PUBLIC ${LEANRT_LIB}
    )

    target_compile_features(xeus-lean-static PRIVATE cxx_std_17)

    if(EMSCRIPTEN)
        target_compile_options(xeus-lean-static PRIVATE -fPIC -g2)
    endif()

    # xlean WASM executable
    # ======================
    add_executable(xlean src/main_emscripten_kernel.cpp)
    target_link_libraries(xlean PRIVATE xeus-lite)
    target_link_libraries(xlean PRIVATE xeus-lean-static)

    # Always-on exports: symbols that the JS side calls back into wasm
    # for housekeeping (poll the %load progress queue, etc.).  Without
    # them wasm-ld's LTO would garbage-collect the function because the
    # C++ side never references it.
    #
    # Downstream third-party libs add their own exports through the
    # EXTRA_WASM_DIRS path below.
    set(_xlean_core_exports "_xlean_poll_load_progress")
    set(_xlean_core_exports_file "${CMAKE_BINARY_DIR}/xlean_core_exports.txt")
    file(WRITE "${_xlean_core_exports_file}" "[${_xlean_core_exports}]")
    set_property(TARGET xlean APPEND_STRING PROPERTY LINK_FLAGS
        " -sEXPORTED_FUNCTIONS=@${_xlean_core_exports_file}")
    # ========================================================================
    # Third-party static libraries (optional) — wired via -DEXTRA_WASM_DIRS
    # ========================================================================
    # Generic plug-in point for downstream Lean libraries to attach
    # their WASM artefacts (static archive + C extern exports + olean
    # tree) to the xlean build.  xeus-lean knows none of their names;
    # everything is data-driven from each staging directory's manifest.
    #
    # Manifest schema (`<staging>/xeus-lean-extra.json`):
    #
    #   {
    #     "archive":    "lib/libNAME_wasm.a",   // whole-archived into xlean
    #     "exports":    "lib/NAME_exports.txt", // splatted into EXPORTED_FUNCTIONS
    #     "olean_root": "TopLevelModule"        // optional, copied to /lib/lean/
    #   }
    #
    # See README.md (`## Extending the kernel with your own Lean lib`)
    # and `tests/fixtures/mock-extra/` for a worked example.

    set(_extra_olean_specs "")     # filled in below, consumed by the
                                   # olean stage near LEAN_OLEAN_SRC.
    set(_extra_archive_paths "")   # also filled in below; consumed by
                                   # the symbol-table generator and the
                                   # test_wasm_node link further down.
    foreach(_extra_dir IN LISTS EXTRA_WASM_DIRS)
        set(_manifest "${_extra_dir}/xeus-lean-extra.json")
        if(NOT EXISTS "${_manifest}")
            message(FATAL_ERROR
                "EXTRA_WASM_DIRS entry ${_extra_dir} is missing xeus-lean-extra.json.\n"
                "Expected schema:\n"
                "  { \"archive\": \"lib/libNAME_wasm.a\",\n"
                "    \"exports\": \"lib/NAME_exports.txt\",\n"
                "    \"olean_root\": \"TopLevelModule\" }")
        endif()
        file(READ "${_manifest}" _meta)
        string(JSON _rel_archive   GET "${_meta}" archive)
        string(JSON _rel_exports   GET "${_meta}" exports)
        # `olean_root` is optional — a pure C library (no Lean side) can
        # omit it.  string(JSON) errors fatally on a missing key, so probe
        # first via the "MEMBER" query.
        string(JSON _olean_root ERROR_VARIABLE _err GET "${_meta}" olean_root)
        if(_err)
            set(_olean_root "")
        endif()

        set(_archive "${_extra_dir}/${_rel_archive}")
        set(_exports "${_extra_dir}/${_rel_exports}")
        if(NOT EXISTS "${_archive}")
            message(FATAL_ERROR "EXTRA_WASM_DIRS: ${_archive} is missing — rerun the third-party build script")
        endif()
        if(NOT EXISTS "${_exports}")
            message(FATAL_ERROR "EXTRA_WASM_DIRS: ${_exports} is missing — rerun the third-party build script")
        endif()

        file(STRINGS "${_exports}" _syms)
        list(LENGTH _syms _n_syms)
        list(JOIN _syms "," _csv)
        get_filename_component(_exports_stem "${_exports}" NAME_WE)
        set(_exports_emcc "${CMAKE_BINARY_DIR}/${_exports_stem}_emcc.txt")
        file(WRITE "${_exports_emcc}" "[${_csv}]")
        message(STATUS "EXTRA_WASM_DIRS: linking ${_archive} (${_n_syms} symbols, "
                "manifest=${_manifest})")
        set_property(TARGET xlean APPEND_STRING PROPERTY LINK_FLAGS
            " -Wl,--whole-archive ${_archive} -Wl,--no-whole-archive -sEXPORTED_FUNCTIONS=@${_exports_emcc}")
        list(APPEND _extra_archive_paths "${_archive}")

        if(_olean_root)
            # Defer the olean copy until the LEAN_OLEAN_SRC block sets up
            # OLEAN_ASSETS_DIR.  Encode "<dir>|<root>" so a single foreach
            # later can dispatch.
            list(APPEND _extra_olean_specs "${_extra_dir}|${_olean_root}")
        endif()
    endforeach()

    # Link stage0 libraries (order matters: REPL -> Lean -> Std -> Init -> leanrt)
    target_link_libraries(xlean PRIVATE
        ${STAGE0_REPL_LIB}
        ${STAGE0_LEAN_LIB}
        ${STAGE0_STD_LIB}
        ${STAGE0_INIT_LIB}
        ${LEANRT_LIB}
    )
    target_compile_options(xlean PRIVATE -fPIC -g2)

    # Compile options (replaces xeus_wasm_compile_options)
    target_compile_options(xlean
        PUBLIC --std=c++17
        PUBLIC -Wno-deprecated
        PUBLIC "SHELL: -fwasm-exceptions"
    )
    set_property(TARGET xlean PROPERTY POSITION_INDEPENDENT_CODE ON)

    # Link options - set directly instead of using xeus_wasm_link_options
    # to avoid duplicate flags and critically to REMOVE MAIN_MODULE=1.
    # MAIN_MODULE=1 (dynamic linking) prevents ALLOW_MEMORY_GROWTH and
    # MAXIMUM_MEMORY from working, causing std::bad_alloc when loading
    # Init modules. We link everything statically so it's not needed.
    target_link_options(xlean
        PUBLIC "SHELL: -lembind"
        PUBLIC -Wno-unused-command-line-argument
        PUBLIC "SHELL: -fwasm-exceptions"
        PUBLIC "SHELL: -s MODULARIZE=1"
        PUBLIC "SHELL: -s EXPORT_NAME=\"createXeusModule\""
        PUBLIC "SHELL: -s EXPORT_ES6=0"
        PUBLIC "SHELL: -s ASSERTIONS=2"
        PUBLIC "SHELL: -s ALLOW_MEMORY_GROWTH=1"
        PUBLIC "SHELL: -s EXIT_RUNTIME=1"
        PUBLIC "SHELL: -s WASM=1"
        PUBLIC "SHELL: -s ENVIRONMENT=web,worker,node"
        PUBLIC "SHELL: -s STACK_SIZE=64mb"
        PUBLIC "SHELL: -s INITIAL_MEMORY=1024mb"
        # 4 GB is the practical ceiling Chromium will allow a single
        # renderer to address; bumping MAXIMUM_MEMORY higher doesn't
        # help because the worker hits the V8 isolate cap (jsHeap-
        # SizeLimit ~3.76 GB) long before wasm linear memory does.
        # We tried 8192MB and Mathlib still failed at the same chunk
        # — the bottleneck is JS-side Blob/Uint8Array accumulation,
        # not wasm pages.  See loadManifestAsync's
        # _xleanSkipExpandedCache flag for the actual workaround.
        PUBLIC "SHELL: -s MAXIMUM_MEMORY=4gb"
        PUBLIC "SHELL: -s WASM_BIGINT"
        PUBLIC "SHELL: -s EXPORTED_RUNTIME_METHODS='[\"FS\",\"ENV\",\"PATH\",\"ERRNO_CODES\",\"getExceptionMessage\",\"getCppExceptionTag\"]'"
        PUBLIC "SHELL: -s FORCE_FILESYSTEM"
        # libxeus from emscripten-forge is a shared library (side module)
        PUBLIC "SHELL: -s MAIN_MODULE=1"
        # No -s ASYNCIFY=*.  We tried both:
        # * ASYNCIFY=1 (binaryen pass) UNREACHABLEs at
        #   Asyncify.cpp:1142 when combined with -sMEMORY64=1 (the
        #   pass can't rewrite 64-bit-pointer expressions).
        # * ASYNCIFY=2 (JSPI) only wraps main() with
        #   WebAssembly.promising by default, but xeus's kernel loop
        #   dispatches to execute_request_impl via std::function
        #   callbacks that emcc doesn't see in main's call graph, so
        #   suspension trips on `trying to suspend without
        #   WebAssembly.promising`.  Manual JSPI_EXPORTS=[<mangled
        #   xeus symbol>] would work but is fragile across libxeus
        #   versions.
        # Instead the `%load <bundle>` magic kicks loadManifestAsync
        # as fire-and-forget JS (the cell's stdout shows progress)
        # and returns immediately.  Users wait, then run the next
        # cell once the log says the bundle is ready.
        # EXPORT_ALL=1 did not retain third-party IR symbols; we use
        # --whole-archive on EXTRA_WASM_DIRS archives instead.
    )

    target_link_options(xlean
        PUBLIC "SHELL: --pre-js ${CMAKE_CURRENT_SOURCE_DIR}/src/pre.js"
        # Order matters: fzstd defines `self.fzstd`/`globalThis.fzstd` and
        # post.js consumes it. Both files end up as separate scripts inside
        # the emscripten worker bundle and run in declaration order.
        PUBLIC "SHELL: --post-js ${CMAKE_CURRENT_SOURCE_DIR}/src/fzstd.umd.js"
        PUBLIC "SHELL: --post-js ${CMAKE_CURRENT_SOURCE_DIR}/src/post.js"
    )

    # Embed Lean .olean files for Init module
    # ========================================
    # The Lean elaborator needs .olean files to import modules (e.g. `import Init`).
    # We copy them from the host Lean toolchain to a staging directory and embed
    # them in the WASM virtual filesystem via --embed-file (data is embedded
    # directly in the JS file, avoiding fetch issues in Web Worker contexts).

    if(NOT LEAN_TOOLCHAIN_DIR)
        # Try to find lean on the host system (not cross-compiled)
        find_program(LEAN_HOST_EXECUTABLE lean
            HINTS $ENV{HOME}/.elan/bin
            NO_CMAKE_FIND_ROOT_PATH)
        if(LEAN_HOST_EXECUTABLE)
            execute_process(
                COMMAND ${LEAN_HOST_EXECUTABLE} --print-prefix
                OUTPUT_VARIABLE LEAN_TOOLCHAIN_DIR
                OUTPUT_STRIP_TRAILING_WHITESPACE
                ERROR_QUIET)
        endif()
    endif()

    if(LEAN_TOOLCHAIN_DIR)
        set(LEAN_OLEAN_SRC "${LEAN_TOOLCHAIN_DIR}/lib/lean")
        set(LEAN_OLEAN_STAGING "${CMAKE_BINARY_DIR}/olean_staging/lib/lean")

        if(EXISTS "${LEAN_OLEAN_SRC}/Init.olean")
            message(STATUS "Lean .olean source: ${LEAN_OLEAN_SRC}")

            # Init .olean files used to be `--embed-file`'d into
            # xlean.wasm so they were available immediately at
            # WASM main() entry.  Init is ~350MB of olean which
            # blew the WASM binary up to ~480MB, all of which the
            # browser had to decode and keep in Linear Memory for
            # every notebook.  Now we ship Init as a tarball
            # alongside Std/Lean + EXTRA_WASM_DIRS (see OLEAN_ASSETS_DIR
            # below); post.js fetches and unpacks it in preRun,
            # which blocks WASM main() until /lib/lean/Init/ is
            # populated, so the runtime sees the same VFS layout
            # as before.
            #
            # What still needs embedding: Display + CommBus.
            # These are tiny (~hundreds of KB) and our auto-import
            # logic in REPL/Frontend touches them on cell 1, so
            # having them available without a separate fetch
            # simplifies boot.  Anything else added to
            # LEAN_OLEAN_STAGING below also gets embedded.
            file(MAKE_DIRECTORY "${LEAN_OLEAN_STAGING}")

            # Embed Display + CommBus (small + always-imported) via
            # --embed-file (baked into the WASM binary).  Std / Lean /
            # Init + EXTRA_WASM_DIRS olean trees are dynamic-load (tarballs).
            set(LEAN_OLEAN_STAGING_ROOT "${CMAKE_BINARY_DIR}/olean_staging")
            target_link_options(xlean
                PUBLIC "SHELL: --embed-file ${LEAN_OLEAN_STAGING_ROOT}@/")

            message(STATUS "Display+CommBus .olean files will be embedded; Init lives in the runtime tarball")

            # Init / Std / Lean .olean files are NOT embedded (too
            # large for WASM).  They are copied to a separate
            # directory and installed as static assets.  The JS
            # runtime fetches them at boot via fetch+FS.writeFile
            # (see src/post.js) and IndexedDB-caches the parsed
            # entries so repeat boots are near-instant.
            set(OLEAN_ASSETS_DIR "${CMAKE_BINARY_DIR}/olean_assets/lib/lean")
            file(MAKE_DIRECTORY "${OLEAN_ASSETS_DIR}")

            # Copy Init artifacts (top-level + recursive).  These
            # used to be embedded via --embed-file but the resulting
            # 480MB WASM binary was painful to load in the browser;
            # streaming them in via a tarball lets the same bytes
            # arrive as compressed data (~70MB) and unpacks just
            # the entries the kernel actually touches.
            if(EXISTS "${LEAN_OLEAN_SRC}/Init.olean")
                foreach(_ext olean olean.server olean.private ir ilean)
                    if(EXISTS "${LEAN_OLEAN_SRC}/Init.${_ext}")
                        file(COPY "${LEAN_OLEAN_SRC}/Init.${_ext}" DESTINATION "${OLEAN_ASSETS_DIR}/")
                    endif()
                endforeach()
                file(GLOB_RECURSE _INIT_FILES RELATIVE "${LEAN_OLEAN_SRC}"
                    "${LEAN_OLEAN_SRC}/Init/*.olean" "${LEAN_OLEAN_SRC}/Init/*.olean.server"
                    "${LEAN_OLEAN_SRC}/Init/*.olean.private"
                    "${LEAN_OLEAN_SRC}/Init/*.ir" "${LEAN_OLEAN_SRC}/Init/*.ilean")
                list(LENGTH _INIT_FILES _init_count)
                message(STATUS "Init: ${_init_count} files → olean_assets (dynamic load)")
                foreach(_f ${_INIT_FILES})
                    get_filename_component(_dir "${_f}" DIRECTORY)
                    file(MAKE_DIRECTORY "${OLEAN_ASSETS_DIR}/${_dir}")
                    file(COPY "${LEAN_OLEAN_SRC}/${_f}" DESTINATION "${OLEAN_ASSETS_DIR}/${_dir}/")
                endforeach()
            endif()

            # Copy Std .olean + .olean.server + .olean.private + .ir + .ilean
            # NOTE: .olean.server is required because Lean's findOLeanParts
            # only loads .olean.private if .olean.server exists alongside it.
            if(EXISTS "${LEAN_OLEAN_SRC}/Std.olean")
                foreach(_ext olean olean.server olean.private ir ilean)
                    if(EXISTS "${LEAN_OLEAN_SRC}/Std.${_ext}")
                        file(COPY "${LEAN_OLEAN_SRC}/Std.${_ext}" DESTINATION "${OLEAN_ASSETS_DIR}/")
                    endif()
                endforeach()
                file(GLOB_RECURSE _STD_FILES RELATIVE "${LEAN_OLEAN_SRC}"
                    "${LEAN_OLEAN_SRC}/Std/*.olean" "${LEAN_OLEAN_SRC}/Std/*.olean.server"
                    "${LEAN_OLEAN_SRC}/Std/*.olean.private"
                    "${LEAN_OLEAN_SRC}/Std/*.ir" "${LEAN_OLEAN_SRC}/Std/*.ilean")
                list(LENGTH _STD_FILES _std_count)
                message(STATUS "Std: ${_std_count} files → olean_assets (dynamic load)")
                foreach(_f ${_STD_FILES})
                    get_filename_component(_dir "${_f}" DIRECTORY)
                    file(MAKE_DIRECTORY "${OLEAN_ASSETS_DIR}/${_dir}")
                    file(COPY "${LEAN_OLEAN_SRC}/${_f}" DESTINATION "${OLEAN_ASSETS_DIR}/${_dir}/")
                endforeach()
            endif()

            # Copy Lean .olean + .olean.server + .olean.private + .ir + .ilean
            if(EXISTS "${LEAN_OLEAN_SRC}/Lean.olean")
                foreach(_ext olean olean.server olean.private ir ilean)
                    if(EXISTS "${LEAN_OLEAN_SRC}/Lean.${_ext}")
                        file(COPY "${LEAN_OLEAN_SRC}/Lean.${_ext}" DESTINATION "${OLEAN_ASSETS_DIR}/")
                    endif()
                endforeach()
                file(GLOB_RECURSE _LEAN_FILES RELATIVE "${LEAN_OLEAN_SRC}"
                    "${LEAN_OLEAN_SRC}/Lean/*.olean" "${LEAN_OLEAN_SRC}/Lean/*.olean.server"
                    "${LEAN_OLEAN_SRC}/Lean/*.olean.private"
                    "${LEAN_OLEAN_SRC}/Lean/*.ir" "${LEAN_OLEAN_SRC}/Lean/*.ilean")
                list(LENGTH _LEAN_FILES _lean_count)
                message(STATUS "Lean: ${_lean_count} files → olean_assets (dynamic load)")
                foreach(_f ${_LEAN_FILES})
                    get_filename_component(_dir "${_f}" DIRECTORY)
                    file(MAKE_DIRECTORY "${OLEAN_ASSETS_DIR}/${_dir}")
                    file(COPY "${LEAN_OLEAN_SRC}/${_f}" DESTINATION "${OLEAN_ASSETS_DIR}/${_dir}/")
                endforeach()
            endif()

            # Also embed Display.olean (from the project's .lake build)
            # so that the REPL can `import Display` at runtime. This makes
            # #html / #latex / #md / #svg / #json commands available to
            # user cells without an explicit import.
            #
            # CommBus is imported by Display, so its olean must be in the
            # VFS too — otherwise `import Display` fails at the header
            # stage with "unknown module prefix 'CommBus'", which then
            # cascades into Init/Std/Lean being skipped and the
            # cell crashing on basic identifiers like `IO.println`.
            set(DISPLAY_OLEAN_SRC "${CMAKE_SOURCE_DIR}/.lake/build/lib/lean")
            foreach(_mod Display CommBus)
                foreach(_ext olean olean.server olean.private ir)
                    if(EXISTS "${DISPLAY_OLEAN_SRC}/${_mod}.${_ext}")
                        file(COPY "${DISPLAY_OLEAN_SRC}/${_mod}.${_ext}" DESTINATION "${LEAN_OLEAN_STAGING}/")
                        message(STATUS "Embedding ${_mod}.${_ext} in WASM VFS")
                    endif()
                endforeach()
            endforeach()
            # Third-party Lean libraries are pulled
            # in via EXTRA_WASM_DIRS — see the _extra_olean_specs loop
            # below.  xeus-lean itself stages only the Lean toolchain
            # oleans (Init/Std/Lean) and Display.

            # Stage third-party olean trees declared via EXTRA_WASM_DIRS.
            # Each spec is "<dir>|<olean_root>" — copy
            # <dir>/<root>{,/**}.{olean,olean.private,olean.server,ir,ilean}
            # into ${OLEAN_ASSETS_DIR}.  Same shape as the toolchain branch
            # above; the loop has zero hard-coded module names.
            foreach(_spec IN LISTS _extra_olean_specs)
                string(REPLACE "|" ";" _parts "${_spec}")
                list(GET _parts 0 _src_dir)
                list(GET _parts 1 _root)
                # A lib may ship as a single umbrella olean
                # (`<src_dir>/<root>.olean` only, no sub-tree) or as
                # an umbrella + tree.  Accept either; only warn if
                # both the umbrella and the tree are missing.
                set(_has_umbrella FALSE)
                if(EXISTS "${_src_dir}/${_root}.olean")
                    set(_has_umbrella TRUE)
                endif()
                set(_has_tree FALSE)
                if(IS_DIRECTORY "${_src_dir}/${_root}")
                    set(_has_tree TRUE)
                endif()
                if(NOT _has_umbrella AND NOT _has_tree)
                    message(WARNING
                        "EXTRA_WASM_DIRS: ${_src_dir} declared olean_root="
                        "${_root} but neither ${_src_dir}/${_root}.olean "
                        "nor ${_src_dir}/${_root}/ exists — skipping")
                    continue()
                endif()
                foreach(_ext olean olean.private)
                    if(EXISTS "${_src_dir}/${_root}.${_ext}")
                        file(COPY "${_src_dir}/${_root}.${_ext}"
                             DESTINATION "${OLEAN_ASSETS_DIR}/")
                    endif()
                endforeach()
                set(_extra_count 0)
                if(_has_tree)
                    file(GLOB_RECURSE _EXTRA_FILES RELATIVE "${_src_dir}"
                        "${_src_dir}/${_root}/*.olean"
                        "${_src_dir}/${_root}/*.olean.server"
                        "${_src_dir}/${_root}/*.olean.private"
                        "${_src_dir}/${_root}/*.ir"
                        "${_src_dir}/${_root}/*.ilean")
                    list(LENGTH _EXTRA_FILES _extra_count)
                    foreach(_f ${_EXTRA_FILES})
                        get_filename_component(_dir "${_f}" DIRECTORY)
                        file(MAKE_DIRECTORY "${OLEAN_ASSETS_DIR}/${_dir}")
                        file(COPY "${_src_dir}/${_f}" DESTINATION "${OLEAN_ASSETS_DIR}/${_dir}/")
                    endforeach()
                endif()
                # Stage the .xeus-auto-imports registry if the
                # third-party staging dir shipped one.  Lives at the
                # OLEAN_ASSETS_DIR root so xlean's REPL scanner picks
                # it up alongside the toolchain auto-imports.
                # Multiple EXTRA_WASM_DIRS entries can each ship one;
                # we append each to a single file rather than
                # overwriting.
                if(EXISTS "${_src_dir}/.xeus-auto-imports")
                    file(READ "${_src_dir}/.xeus-auto-imports" _ai_body)
                    file(APPEND "${OLEAN_ASSETS_DIR}/.xeus-auto-imports"
                                "# from EXTRA_WASM_DIRS=${_src_dir}\n${_ai_body}\n")
                    message(STATUS "EXTRA_WASM_DIRS: ${_root}: merged .xeus-auto-imports")
                endif()
                message(STATUS "EXTRA_WASM_DIRS: ${_root}: ${_extra_count} files → olean_assets"
                              " (umbrella=${_has_umbrella} tree=${_has_tree})")
            endforeach()

            # Generate manifest.json listing all .olean asset files
            file(GLOB_RECURSE _ALL_ASSET_FILES
                RELATIVE "${CMAKE_BINARY_DIR}/olean_assets/lib/lean"
                "${CMAKE_BINARY_DIR}/olean_assets/lib/lean/*.olean"
                "${CMAKE_BINARY_DIR}/olean_assets/lib/lean/*.olean.server"
                "${CMAKE_BINARY_DIR}/olean_assets/lib/lean/*.olean.private"
                "${CMAKE_BINARY_DIR}/olean_assets/lib/lean/*.ir"
                "${CMAKE_BINARY_DIR}/olean_assets/lib/lean/*.ilean")
            # Write JSON array
            set(_manifest_json "[")
            set(_first TRUE)
            foreach(_f ${_ALL_ASSET_FILES})
                if(_first)
                    set(_first FALSE)
                else()
                    string(APPEND _manifest_json ",")
                endif()
                string(APPEND _manifest_json "\"${_f}\"")
            endforeach()
            string(APPEND _manifest_json "]")
            file(WRITE "${CMAKE_BINARY_DIR}/olean_assets/lib/lean/manifest.json" "${_manifest_json}")
            list(LENGTH _ALL_ASSET_FILES _total_assets)
            message(STATUS "Generated olean manifest: ${_total_assets} files")

            # Install olean_assets so they're served as static files.
            install(DIRECTORY "${CMAKE_BINARY_DIR}/olean_assets/lib/lean/"
                    DESTINATION "share/jupyter/olean"
                    OPTIONAL)
        else()
            message(WARNING "Init.olean not found at ${LEAN_OLEAN_SRC}/Init.olean - WASM kernel will have no Init module")
        endif()
    else()
        message(WARNING "Lean toolchain not found. Set -DLEAN_TOOLCHAIN_DIR=<path> to embed .olean files.")
    endif()

    # Generate WASM symbol lookup table
    # ==================================
    # In WASM, dlsym doesn't work without -sMAIN_MODULE.
    # We generate a static lookup table from all symbols in our libraries.
    include(GenerateSymbolTable)
    set(WASM_SYMTAB_FILE "${CMAKE_BINARY_DIR}/wasm_symbol_table.cpp")
    set(_symtab_libs
        ${LEANRT_LIB}
        ${STAGE0_INIT_LIB}
        ${STAGE0_STD_LIB}
        ${STAGE0_LEAN_LIB}
        ${STAGE0_REPL_LIB}
    )
    # Add every archive contributed via EXTRA_WASM_DIRS so its Lean
    # externs end up in the dlsym lookup table too.
    foreach(_extra_archive_path IN LISTS _extra_archive_paths)
        list(APPEND _symtab_libs "${_extra_archive_path}")
    endforeach()
    generate_wasm_symbol_table(${WASM_SYMTAB_FILE} ${_symtab_libs})

    # Add symbol table to xlean (generated above)
    target_sources(xlean PRIVATE ${WASM_SYMTAB_FILE})

    # Node.js test executable (standalone, no xeus dependency)
    # ========================================================

    add_executable(test_wasm_node test_wasm_node.cpp ${WASM_SYMTAB_FILE})
    target_include_directories(test_wasm_node PRIVATE ${LEAN4_INCLUDE_DIR})
    target_link_libraries(test_wasm_node PRIVATE
        ${STAGE0_REPL_LIB}
        ${STAGE0_LEAN_LIB}
        ${STAGE0_STD_LIB}
        ${STAGE0_INIT_LIB}
        ${LEANRT_LIB}
    )
    # wasm_symbol_table.cpp references symbols from each
    # EXTRA_WASM_DIRS archive — pull them in via whole-archive so
    # the references resolve at link time.
    foreach(_extra_archive_path IN LISTS _extra_archive_paths)
        target_link_options(test_wasm_node PRIVATE
            "SHELL: -Wl,--whole-archive ${_extra_archive_path} -Wl,--no-whole-archive"
        )
    endforeach()
    target_compile_options(test_wasm_node PRIVATE -fPIC -g2)
    target_link_options(test_wasm_node PRIVATE
        "SHELL: -fwasm-exceptions"
        "SHELL: -sALLOW_MEMORY_GROWTH=1"
        "SHELL: -sINITIAL_MEMORY=4096mb"
        "SHELL: -sMAXIMUM_MEMORY=4gb"
        "SHELL: -sSTACK_SIZE=64mb"
        "SHELL: -sFORCE_FILESYSTEM"
        "SHELL: -sENVIRONMENT=node"
        "SHELL: -sEXIT_RUNTIME=0"
        "SHELL: -sASSERTIONS=0"
        "SHELL: -sNODERAWFS=0"
        "SHELL: -sWASM_BIGINT"
        "SHELL: -sEXPORTED_FUNCTIONS=_main"
        "SHELL: -sEXPORTED_RUNTIME_METHODS=FS,ENV,PATH"
        "SHELL: -sEXPORT_ALL=1"
        "SHELL: --profiling-funcs"
    )
    # test_wasm_node only needs Init .olean files (not Std/Lean) plus
    # whatever EXTRA_WASM_DIRS contributed so the mock-extra fixture
    # (and any future plug-in test) can resolve `import MockExtra`
    # against its embedded VFS.
    if(LEAN_TOOLCHAIN_DIR AND EXISTS "${LEAN_OLEAN_SRC}/Init.olean")
        set(TEST_OLEAN_STAGING "${CMAKE_BINARY_DIR}/test_olean_staging/lib/lean")
        file(MAKE_DIRECTORY "${TEST_OLEAN_STAGING}")
        # Use shell `cp` instead of cmake file(COPY) which is O(n) syscalls
        # and can take 15+ minutes on slow filesystems for 2K+ files.
        # Includes .olean (kernel), .olean.server (server data), .olean.private,
        # and .ir / .ilean — all needed for module imports in the WASM REPL.
        execute_process(
            COMMAND sh -c "cp -f \"${LEAN_OLEAN_SRC}\"/Init.olean \"${LEAN_OLEAN_SRC}\"/Init.olean.server \"${LEAN_OLEAN_SRC}\"/Init.olean.private \"${LEAN_OLEAN_SRC}\"/Init.ir \"${LEAN_OLEAN_SRC}\"/Init.ilean \"${TEST_OLEAN_STAGING}/\" 2>/dev/null; cp -rf \"${LEAN_OLEAN_SRC}/Init\" \"${TEST_OLEAN_STAGING}/\""
            RESULT_VARIABLE _cp_rc)
        if(_cp_rc)
            message(WARNING "Init staging copy failed: rc=${_cp_rc}")
        endif()
        # Stage every EXTRA_WASM_DIRS olean root + its
        # .xeus-auto-imports into the same test VFS, mirroring what
        # xlean does for the deploy target.
        foreach(_spec IN LISTS _extra_olean_specs)
            string(REPLACE "|" ";" _parts "${_spec}")
            list(GET _parts 0 _src_dir)
            list(GET _parts 1 _root)
            foreach(_ext olean olean.server olean.private ir ilean)
                if(EXISTS "${_src_dir}/${_root}.${_ext}")
                    file(COPY "${_src_dir}/${_root}.${_ext}"
                         DESTINATION "${TEST_OLEAN_STAGING}/")
                endif()
            endforeach()
            if(IS_DIRECTORY "${_src_dir}/${_root}")
                file(COPY "${_src_dir}/${_root}"
                     DESTINATION "${TEST_OLEAN_STAGING}/")
            endif()
            if(EXISTS "${_src_dir}/.xeus-auto-imports")
                file(READ "${_src_dir}/.xeus-auto-imports" _ai_body)
                file(APPEND "${TEST_OLEAN_STAGING}/.xeus-auto-imports"
                            "# from EXTRA_WASM_DIRS=${_src_dir}\n${_ai_body}\n")
            endif()
            message(STATUS "test_wasm_node: staged ${_root} from ${_src_dir}")
        endforeach()
        target_link_options(test_wasm_node
            PUBLIC "SHELL: --embed-file ${CMAKE_BINARY_DIR}/test_olean_staging@/")
    endif()

    # Installation
    # ============

    # Install WASM artifacts
    install(TARGETS xlean
            ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})

    install(FILES
            "$<TARGET_FILE_DIR:xlean>/xlean.js"
            "$<TARGET_FILE_DIR:xlean>/xlean.wasm"
            DESTINATION ${CMAKE_INSTALL_BINDIR})

    # --preload-file generates xlean.data containing all .olean files.
    # It must be served alongside xlean.js for the VFS to work.
    install(FILES "$<TARGET_FILE_DIR:xlean>/xlean.data"
            DESTINATION ${CMAKE_INSTALL_BINDIR}
            OPTIONAL)

    # Install kernel spec
    # jupyterlite-xeus locates <argv[0]>.js / .wasm, so argv[0] must be the
    # full path of the installed kernel binary (as done by xeus-python)
    set(XJUPYTER_DATA_DIR "share/jupyter" CACHE STRING "Jupyter data directory")
    set(XEUS_LEAN_KERNELSPEC_PATH "${CMAKE_INSTALL_FULL_BINDIR}/")
    configure_file(
        "${CMAKE_CURRENT_SOURCE_DIR}/share/jupyter/kernels/xlean/kernel.json.in"
        "${CMAKE_CURRENT_BINARY_DIR}/share/jupyter/kernels/xlean/kernel.json")
    set(KERNELSPEC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/share/jupyter/kernels)
    install(DIRECTORY ${KERNELSPEC_DIR}
            DESTINATION ${XJUPYTER_DATA_DIR}
            PATTERN "*.in" EXCLUDE)
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/share/jupyter/kernels/xlean/kernel.json"
            DESTINATION ${XJUPYTER_DATA_DIR}/kernels/xlean)

# ============================================================================
# NATIVE BUILD (existing)
# ============================================================================

else()
    message(STATUS "Building xeus-lean native FFI library")

    # Dependencies (from the conda / pixi environment)
    # ===============================================

    find_package(nlohmann_json 3.11.3 REQUIRED)
    set(JSON_TARGET nlohmann_json::nlohmann_json)
    find_package(xeus 6.0 REQUIRED)
    find_package(xeus-zmq 4.0 REQUIRED)

    # Lean Integration
    # ================

    # Find Lean installation
    find_program(LEAN_EXECUTABLE lean REQUIRED)

    execute_process(
        COMMAND ${LEAN_EXECUTABLE} --print-prefix
        OUTPUT_VARIABLE LEAN_PREFIX
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )

    message(STATUS "Found Lean at: ${LEAN_PREFIX}")

    # Set Lean include and library paths
    set(LEAN_INCLUDE_DIR "${LEAN_PREFIX}/include")
    set(LEAN_LIB_DIR "${LEAN_PREFIX}/lib/lean")

    # Find Lean runtime libraries
    find_library(LEAN_LIBRARY NAMES leanshared lean PATHS ${LEAN_LIB_DIR} REQUIRED)

    message(STATUS "Lean library: ${LEAN_LIBRARY}")
    message(STATUS "Lean include dir: ${LEAN_INCLUDE_DIR}")

    # xeus FFI library (for Lean to call)
    # ====================================

    add_library(xeus_ffi STATIC src/xeus_ffi.cpp)
    target_compile_features(xeus_ffi PRIVATE cxx_std_17)

    # Link with xeus
    target_link_libraries(xeus_ffi PUBLIC xeus)
    target_link_libraries(xeus_ffi PUBLIC xeus-zmq)
    target_link_libraries(xeus_ffi PUBLIC ${JSON_TARGET})
    target_include_directories(xeus_ffi PUBLIC ${LEAN_INCLUDE_DIR})
    target_link_libraries(xeus_ffi PUBLIC ${LEAN_LIBRARY})

    find_package(Threads)
    target_link_libraries(xeus_ffi PRIVATE ${CMAKE_THREAD_LIBS_INIT})

    # Set rpath for the FFI library
    set_target_properties(xeus_ffi PROPERTIES
        BUILD_WITH_INSTALL_RPATH TRUE
        INSTALL_RPATH "${LEAN_LIB_DIR};${CMAKE_BINARY_DIR}/_deps/xeus-build;${CMAKE_BINARY_DIR}/_deps/xeus-zmq-build"
        INSTALL_RPATH_USE_LINK_PATH TRUE
    )

    message(STATUS "xeus FFI library configured")

endif()

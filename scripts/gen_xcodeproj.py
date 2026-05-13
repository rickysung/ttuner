#!/usr/bin/env python3
"""Generate a .pbxproj for the ttuner iOS app + unit-test target.

Run from the repo root or via `python3 scripts/gen_xcodeproj.py`.
Rewrites `ttuner.xcodeproj/project.pbxproj`, the workspace data, and the
shared scheme so they reflect the current Swift / Metal / test sources on
disk. Safe to run any time files are added or renamed.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_DIR = os.path.join(ROOT, "ttuner")
TESTS_DIR = os.path.join(ROOT, "ttunerTests")
PROJECT_DIR = os.path.join(ROOT, "ttuner.xcodeproj")
PROJ_NAME = "ttuner"
TEST_NAME = "ttunerTests"
BUNDLE_ID = "com.ttuner.app"
TEST_BUNDLE_ID = "com.ttuner.tests"

def uid(key: str) -> str:
    return hashlib.md5(key.encode("utf-8")).hexdigest().upper()[:24]

SRC_DIRS = [
    "App", "Audio", "DSP", "Domain", "Metronome", "Tuner",
    "Rendering", "UI", "Settings",
]

source_files = []
for sub in SRC_DIRS:
    abs_sub = os.path.join(APP_DIR, sub)
    for f in sorted(os.listdir(abs_sub)):
        if f.endswith(".swift") or f.endswith(".metal"):
            kind = "swift" if f.endswith(".swift") else "metal"
            source_files.append({"name": f, "group": sub, "kind": kind, "rel": f"ttuner/{sub}/{f}"})

test_files = []
if os.path.isdir(TESTS_DIR):
    for f in sorted(os.listdir(TESTS_DIR)):
        if f.endswith(".swift"):
            test_files.append({"name": f, "rel": f"ttunerTests/{f}"})

# UUIDs
project_id          = uid("project")
main_group_id       = uid("group:root")
app_group_id        = uid("group:ttuner")
products_group_id   = uid("group:Products")
tests_group_id      = uid("group:ttunerTests")
target_id           = uid("target:ttuner")
test_target_id      = uid("target:ttunerTests")
target_proxy_id     = uid("target:proxy:ttuner")
sources_phase_id    = uid("phase:sources")
frameworks_phase_id = uid("phase:frameworks")
resources_phase_id  = uid("phase:resources")
test_sources_phase  = uid("phase:test:sources")
test_frameworks     = uid("phase:test:frameworks")
test_resources      = uid("phase:test:resources")
proj_config_list_id = uid("configlist:project")
proj_config_debug   = uid("config:project:Debug")
proj_config_rel     = uid("config:project:Release")
tgt_config_list_id  = uid("configlist:target")
tgt_config_debug    = uid("config:target:Debug")
tgt_config_rel      = uid("config:target:Release")
test_config_list_id = uid("configlist:test")
test_config_debug   = uid("config:test:Debug")
test_config_rel     = uid("config:test:Release")
app_product_ref_id  = uid("product:app")
test_product_ref_id = uid("product:tests")
test_dep_id         = uid("dep:tests-on-app")
test_container_proxy = uid("proxy:tests:app")

group_ids = {sub: uid(f"group:{sub}") for sub in SRC_DIRS}
group_ids["Resources"] = uid("group:Resources")

info_plist_file_ref = uid("file:InfoPlist")
assets_file_ref     = uid("file:Assets")
assets_build_file_id = uid("buildfile:Assets")

for sf in source_files:
    sf["file_ref"] = uid("file:" + sf["rel"])
    sf["build_file"] = uid("build:" + sf["rel"])
for tf in test_files:
    tf["file_ref"] = uid("file:" + tf["rel"])
    tf["build_file"] = uid("build:" + tf["rel"])

out = []
out.append("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n")

# PBXBuildFile
out.append("\n/* Begin PBXBuildFile section */\n")
for sf in source_files:
    out.append(f'\t\t{sf["build_file"]} /* {sf["name"]} in Sources */ = {{isa = PBXBuildFile; fileRef = {sf["file_ref"]} /* {sf["name"]} */; }};\n')
for tf in test_files:
    out.append(f'\t\t{tf["build_file"]} /* {tf["name"]} in Sources */ = {{isa = PBXBuildFile; fileRef = {tf["file_ref"]} /* {tf["name"]} */; }};\n')
out.append(f'\t\t{assets_build_file_id} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_file_ref} /* Assets.xcassets */; }};\n')
out.append("/* End PBXBuildFile section */\n")

# PBXContainerItemProxy (for tests target dependency)
out.append("\n/* Begin PBXContainerItemProxy section */\n")
out.append(f'\t\t{test_container_proxy} /* PBXContainerItemProxy */ = {{\n')
out.append('\t\t\tisa = PBXContainerItemProxy;\n')
out.append(f'\t\t\tcontainerPortal = {project_id} /* Project object */;\n')
out.append('\t\t\tproxyType = 1;\n')
out.append(f'\t\t\tremoteGlobalIDString = {target_id};\n')
out.append(f'\t\t\tremoteInfo = {PROJ_NAME};\n')
out.append('\t\t};\n')
out.append("/* End PBXContainerItemProxy section */\n")

# PBXTargetDependency
out.append("\n/* Begin PBXTargetDependency section */\n")
out.append(f'\t\t{test_dep_id} /* PBXTargetDependency */ = {{\n')
out.append('\t\t\tisa = PBXTargetDependency;\n')
out.append(f'\t\t\ttarget = {target_id} /* {PROJ_NAME} */;\n')
out.append(f'\t\t\ttargetProxy = {test_container_proxy} /* PBXContainerItemProxy */;\n')
out.append('\t\t};\n')
out.append("/* End PBXTargetDependency section */\n")

# PBXFileReference
out.append("\n/* Begin PBXFileReference section */\n")
out.append(f'\t\t{app_product_ref_id} /* {PROJ_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{PROJ_NAME}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};\n')
out.append(f'\t\t{test_product_ref_id} /* {TEST_NAME}.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "{TEST_NAME}.xctest"; sourceTree = BUILT_PRODUCTS_DIR; }};\n')
out.append(f'\t\t{info_plist_file_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};\n')
out.append(f'\t\t{assets_file_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};\n')
for sf in source_files:
    filetype = "sourcecode.swift" if sf["kind"] == "swift" else "sourcecode.metal"
    out.append(f'\t\t{sf["file_ref"]} /* {sf["name"]} */ = {{isa = PBXFileReference; lastKnownFileType = {filetype}; path = {sf["name"]}; sourceTree = "<group>"; }};\n')
for tf in test_files:
    out.append(f'\t\t{tf["file_ref"]} /* {tf["name"]} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {tf["name"]}; sourceTree = "<group>"; }};\n')
out.append("/* End PBXFileReference section */\n")

# PBXFrameworksBuildPhase
out.append("\n/* Begin PBXFrameworksBuildPhase section */\n")
out.append(f'\t\t{frameworks_phase_id} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
out.append(f'\t\t{test_frameworks} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
out.append("/* End PBXFrameworksBuildPhase section */\n")

# PBXGroup
out.append("\n/* Begin PBXGroup section */\n")
out.append(f'\t\t{main_group_id} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n')
out.append(f'\t\t\t\t{app_group_id} /* ttuner */,\n')
if test_files:
    out.append(f'\t\t\t\t{tests_group_id} /* ttunerTests */,\n')
out.append(f'\t\t\t\t{products_group_id} /* Products */,\n')
out.append('\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t};\n')

out.append(f'\t\t{products_group_id} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n')
out.append(f'\t\t\t\t{app_product_ref_id} /* {PROJ_NAME}.app */,\n')
if test_files:
    out.append(f'\t\t\t\t{test_product_ref_id} /* {TEST_NAME}.xctest */,\n')
out.append('\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t};\n')

children = []
for sub in SRC_DIRS:
    children.append(f"\t\t\t\t{group_ids[sub]} /* {sub} */,")
children.append(f"\t\t\t\t{group_ids['Resources']} /* Resources */,")
out.append(f'\t\t{app_group_id} /* ttuner */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "\n".join(children) + f'\n\t\t\t);\n\t\t\tpath = ttuner;\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')

for sub in SRC_DIRS:
    files_in_sub = [sf for sf in source_files if sf["group"] == sub]
    ch_lines = [f"\t\t\t\t{sf['file_ref']} /* {sf['name']} */," for sf in files_in_sub]
    out.append(f'\t\t{group_ids[sub]} /* {sub} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "\n".join(ch_lines) + f'\n\t\t\t);\n\t\t\tpath = {sub};\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')

out.append(f'\t\t{group_ids["Resources"]} /* Resources */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{info_plist_file_ref} /* Info.plist */,\n\t\t\t\t{assets_file_ref} /* Assets.xcassets */,\n\t\t\t);\n\t\t\tpath = Resources;\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')

if test_files:
    tf_lines = [f"\t\t\t\t{tf['file_ref']} /* {tf['name']} */," for tf in test_files]
    out.append(f'\t\t{tests_group_id} /* ttunerTests */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "\n".join(tf_lines) + f'\n\t\t\t);\n\t\t\tpath = {TEST_NAME};\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')

out.append("/* End PBXGroup section */\n")

# PBXNativeTarget (app)
out.append("\n/* Begin PBXNativeTarget section */\n")
out.append(f'\t\t{target_id} /* {PROJ_NAME} */ = {{\n')
out.append('\t\t\tisa = PBXNativeTarget;\n')
out.append(f'\t\t\tbuildConfigurationList = {tgt_config_list_id} /* Build configuration list for PBXNativeTarget "{PROJ_NAME}" */;\n')
out.append('\t\t\tbuildPhases = (\n')
out.append(f'\t\t\t\t{sources_phase_id} /* Sources */,\n')
out.append(f'\t\t\t\t{frameworks_phase_id} /* Frameworks */,\n')
out.append(f'\t\t\t\t{resources_phase_id} /* Resources */,\n')
out.append('\t\t\t);\n')
out.append('\t\t\tbuildRules = (\n\t\t\t);\n')
out.append('\t\t\tdependencies = (\n\t\t\t);\n')
out.append(f'\t\t\tname = {PROJ_NAME};\n')
out.append(f'\t\t\tproductName = {PROJ_NAME};\n')
out.append(f'\t\t\tproductReference = {app_product_ref_id} /* {PROJ_NAME}.app */;\n')
out.append('\t\t\tproductType = "com.apple.product-type.application";\n')
out.append('\t\t};\n')

if test_files:
    out.append(f'\t\t{test_target_id} /* {TEST_NAME} */ = {{\n')
    out.append('\t\t\tisa = PBXNativeTarget;\n')
    out.append(f'\t\t\tbuildConfigurationList = {test_config_list_id} /* Build configuration list for PBXNativeTarget "{TEST_NAME}" */;\n')
    out.append('\t\t\tbuildPhases = (\n')
    out.append(f'\t\t\t\t{test_sources_phase} /* Sources */,\n')
    out.append(f'\t\t\t\t{test_frameworks} /* Frameworks */,\n')
    out.append(f'\t\t\t\t{test_resources} /* Resources */,\n')
    out.append('\t\t\t);\n')
    out.append('\t\t\tbuildRules = (\n\t\t\t);\n')
    out.append('\t\t\tdependencies = (\n')
    out.append(f'\t\t\t\t{test_dep_id} /* PBXTargetDependency */,\n')
    out.append('\t\t\t);\n')
    out.append(f'\t\t\tname = {TEST_NAME};\n')
    out.append(f'\t\t\tproductName = {TEST_NAME};\n')
    out.append(f'\t\t\tproductReference = {test_product_ref_id} /* {TEST_NAME}.xctest */;\n')
    out.append('\t\t\tproductType = "com.apple.product-type.bundle.unit-test";\n')
    out.append('\t\t};\n')
out.append("/* End PBXNativeTarget section */\n")

# PBXProject
out.append("\n/* Begin PBXProject section */\n")
out.append(f'\t\t{project_id} /* Project object */ = {{\n')
out.append('\t\t\tisa = PBXProject;\n')
out.append('\t\t\tattributes = {\n')
out.append('\t\t\t\tBuildIndependentTargetsInParallel = YES;\n')
out.append('\t\t\t\tLastSwiftUpdateCheck = 1530;\n')
out.append('\t\t\t\tLastUpgradeCheck = 1530;\n')
out.append('\t\t\t\tTargetAttributes = {\n')
out.append(f'\t\t\t\t\t{target_id} = {{ CreatedOnToolsVersion = 15.3; }};\n')
if test_files:
    out.append(f'\t\t\t\t\t{test_target_id} = {{ CreatedOnToolsVersion = 15.3; TestTargetID = {target_id}; }};\n')
out.append('\t\t\t\t};\n')
out.append('\t\t\t};\n')
out.append(f'\t\t\tbuildConfigurationList = {proj_config_list_id} /* Build configuration list for PBXProject "{PROJ_NAME}" */;\n')
out.append('\t\t\tcompatibilityVersion = "Xcode 14.0";\n')
out.append('\t\t\tdevelopmentRegion = en;\n')
out.append('\t\t\thasScannedForEncodings = 0;\n')
out.append('\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n')
out.append(f'\t\t\tmainGroup = {main_group_id};\n')
out.append(f'\t\t\tproductRefGroup = {products_group_id} /* Products */;\n')
out.append('\t\t\tprojectDirPath = "";\n')
out.append('\t\t\tprojectRoot = "";\n')
out.append('\t\t\ttargets = (\n')
out.append(f'\t\t\t\t{target_id} /* {PROJ_NAME} */,\n')
if test_files:
    out.append(f'\t\t\t\t{test_target_id} /* {TEST_NAME} */,\n')
out.append('\t\t\t);\n')
out.append('\t\t};\n')
out.append("/* End PBXProject section */\n")

# PBXResourcesBuildPhase
out.append("\n/* Begin PBXResourcesBuildPhase section */\n")
out.append(f'\t\t{resources_phase_id} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{assets_build_file_id} /* Assets.xcassets in Resources */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
out.append(f'\t\t{test_resources} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
out.append("/* End PBXResourcesBuildPhase section */\n")

# PBXSourcesBuildPhase
out.append("\n/* Begin PBXSourcesBuildPhase section */\n")
out.append(f'\t\t{sources_phase_id} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n')
for sf in source_files:
    out.append(f"\t\t\t\t{sf['build_file']} /* {sf['name']} in Sources */,\n")
out.append("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")

if test_files:
    out.append(f'\t\t{test_sources_phase} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n')
    for tf in test_files:
        out.append(f"\t\t\t\t{tf['build_file']} /* {tf['name']} in Sources */,\n")
    out.append("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n")
out.append("/* End PBXSourcesBuildPhase section */\n")

# XCBuildConfiguration
out.append("\n/* Begin XCBuildConfiguration section */\n")

base_common = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;
\t\t\t\tCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_COMMA = YES;
\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
\t\t\t\tCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;
\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;
\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = iphoneos;
"""

debug_common = base_common + """\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_NS_ASSERTIONS = YES;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tSWIFT_COMPILATION_MODE = singlefile;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t\tONLY_ACTIVE_ARCH = YES;
"""
release_common = base_common + """\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tVALIDATE_PRODUCT = YES;
"""

out.append(f'\t\t{proj_config_debug} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{debug_common}\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n')
out.append(f'\t\t{proj_config_rel} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{release_common}\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n')

target_common = f"""\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = ttuner/Resources/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
"""
out.append(f'\t\t{tgt_config_debug} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{target_common}\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n')
out.append(f'\t\t{tgt_config_rel} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{target_common}\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n')

if test_files:
    test_common = f"""\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMARKETING_VERSION = 0.1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {TEST_BUNDLE_ID};
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/{PROJ_NAME}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{PROJ_NAME}";
"""
    out.append(f'\t\t{test_config_debug} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{test_common}\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n')
    out.append(f'\t\t{test_config_rel} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{test_common}\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n')
out.append("/* End XCBuildConfiguration section */\n")

# XCConfigurationList
out.append("\n/* Begin XCConfigurationList section */\n")
out.append(f'\t\t{proj_config_list_id} /* Build configuration list for PBXProject "{PROJ_NAME}" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{proj_config_debug} /* Debug */,\n\t\t\t\t{proj_config_rel} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n')
out.append(f'\t\t{tgt_config_list_id} /* Build configuration list for PBXNativeTarget "{PROJ_NAME}" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{tgt_config_debug} /* Debug */,\n\t\t\t\t{tgt_config_rel} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n')
if test_files:
    out.append(f'\t\t{test_config_list_id} /* Build configuration list for PBXNativeTarget "{TEST_NAME}" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{test_config_debug} /* Debug */,\n\t\t\t\t{test_config_rel} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n')
out.append("/* End XCConfigurationList section */\n")

out.append("\t};\n")
out.append(f"\trootObject = {project_id} /* Project object */;\n")
out.append("}\n")

os.makedirs(PROJECT_DIR, exist_ok=True)
pbxproj_path = os.path.join(PROJECT_DIR, "project.pbxproj")
with open(pbxproj_path, "w", encoding="utf-8") as f:
    f.writelines(out)
print(f"Wrote {pbxproj_path}")

# Workspace + scheme files
ws_dir = os.path.join(PROJECT_DIR, "project.xcworkspace")
os.makedirs(ws_dir, exist_ok=True)
ws_data = os.path.join(ws_dir, "contents.xcworkspacedata")
with open(ws_data, "w", encoding="utf-8") as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version = "1.0">\n   <FileRef location = "self:"></FileRef>\n</Workspace>\n')
print(f"Wrote {ws_data}")

shared_ws = os.path.join(ws_dir, "xcshareddata")
os.makedirs(shared_ws, exist_ok=True)
checks = os.path.join(shared_ws, "IDEWorkspaceChecks.plist")
with open(checks, "w", encoding="utf-8") as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n  <key>IDEDidComputeMac32BitWarning</key>\n  <true/>\n</dict>\n</plist>\n')
print(f"Wrote {checks}")

# Scheme
schemes_dir = os.path.join(PROJECT_DIR, "xcshareddata", "xcschemes")
os.makedirs(schemes_dir, exist_ok=True)
scheme_path = os.path.join(schemes_dir, f"{PROJ_NAME}.xcscheme")
test_block = ""
if test_files:
    test_block = f"""
         <TestableReference skipped="NO">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="{test_target_id}"
               BuildableName="{TEST_NAME}.xctest"
               BlueprintName="{TEST_NAME}"
               ReferencedContainer="container:{PROJ_NAME}.xcodeproj">
            </BuildableReference>
         </TestableReference>"""
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1530" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="{target_id}"
               BuildableName="{PROJ_NAME}.app"
               BlueprintName="{PROJ_NAME}"
               ReferencedContainer="container:{PROJ_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>{test_block}
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference
            BuildableIdentifier="primary"
            BlueprintIdentifier="{target_id}"
            BuildableName="{PROJ_NAME}.app"
            BlueprintName="{PROJ_NAME}"
            ReferencedContainer="container:{PROJ_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference
            BuildableIdentifier="primary"
            BlueprintIdentifier="{target_id}"
            BuildableName="{PROJ_NAME}.app"
            BlueprintName="{PROJ_NAME}"
            ReferencedContainer="container:{PROJ_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"></ArchiveAction>
</Scheme>
"""
with open(scheme_path, "w", encoding="utf-8") as f:
    f.write(scheme)
print(f"Wrote {scheme_path}")
print("Done.")

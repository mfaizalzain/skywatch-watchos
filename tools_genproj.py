#!/usr/bin/env python3
"""Generate SkyWatch.xcodeproj/project.pbxproj.

Kept in the repo so the project file can be regenerated rather than hand-patched if it ever
gets mangled.
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
if os.path.basename(ROOT) == "scratchpad":
    ROOT = "/home/user/skywatch-watchos"

APP = "SkyWatch"
WIDGET = "SkyWatchWidget"
TESTS = "SkyWatchTests"
BUNDLE_ROOT = "com.fmz.skywatch"
GROUP_ID = "group.com.fmz.skywatch"
DEPLOYMENT = "26.0"

used_ids = set()


def oid(*parts):
    """Deterministic 24-hex-character object id."""
    key = "|".join(parts)
    digest = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
    while digest in used_ids:
        digest = hashlib.sha256((key + "!").encode()).hexdigest()[:24].upper()
        key += "!"
    used_ids.add(digest)
    return digest


def swift_files(directory):
    out = []
    for base, _, names in os.walk(os.path.join(ROOT, directory)):
        for name in sorted(names):
            if name.endswith(".swift"):
                out.append(os.path.relpath(os.path.join(base, name), ROOT))
    return sorted(out)


APP_SOURCES = swift_files(APP)
WIDGET_OWN = swift_files(WIDGET)
TEST_OWN = swift_files(TESTS)

# Shared sources compiled into the widget: everything the snapshot views touch, and nothing else.
WIDGET_SHARED = [
    "SkyWatch/Geo/Geodesy.swift",
    "SkyWatch/Models/Aircraft.swift",
    "SkyWatch/Models/Units.swift",
    "SkyWatch/Services/SharedStore.swift",
    "SkyWatch/Design/Palette.swift",
    "SkyWatch/Design/Typography.swift",
]

# The test bundle is a logic-test bundle with no host app, so the code under test is compiled
# into it directly. Only UI-free sources qualify.
TEST_SHARED = [
    "SkyWatch/Geo/Geodesy.swift",
    "SkyWatch/Models/Aircraft.swift",
    "SkyWatch/Models/AircraftResponse.swift",
    "SkyWatch/Models/Units.swift",
    "SkyWatch/Services/RateLimiter.swift",
    "SkyWatch/State/TrackedTarget.swift",
    "SkyWatch/Views/Components/ScopeGeometry.swift",
]

APP_RESOURCES = ["SkyWatch/Assets.xcassets", "SkyWatch/Preview Content/Preview Assets.xcassets"]
WIDGET_RESOURCES = ["SkyWatchWidget/Assets.xcassets"]
OTHER_FILES = [
    "SkyWatch/Info.plist",
    "SkyWatch/SkyWatch.entitlements",
    "SkyWatchWidget/Info.plist",
    "SkyWatchWidget/SkyWatchWidget.entitlements",
]

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".plist": "text.plist.xml",
    ".entitlements": "text.plist.entitlements",
    ".xcassets": "folder.assetcatalog",
    ".json": "text.json",
    ".md": "net.daringfireball.markdown",
}

all_paths = sorted(set(APP_SOURCES + WIDGET_OWN + TEST_OWN + APP_RESOURCES + WIDGET_RESOURCES + OTHER_FILES))
file_ref = {path: oid("fileref", path) for path in all_paths}

products = {
    "app": oid("product", "app"),
    "widget": oid("product", "widget"),
    "tests": oid("product", "tests"),
}

lines = []
w = lines.append


def file_reference_section():
    w("/* Begin PBXFileReference section */")
    for path in all_paths:
        ext = os.path.splitext(path)[1]
        ftype = FILE_TYPES.get(ext, "text")
        name = os.path.basename(path)
        w(
            '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = "%s"; sourceTree = "<group>"; };'
            % (file_ref[path], name, ftype, name)
        )
    w(
        '\t\t%s /* SkyWatch.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SkyWatch.app; sourceTree = BUILT_PRODUCTS_DIR; };'
        % products["app"]
    )
    w(
        '\t\t%s /* SkyWatchWidget.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = SkyWatchWidget.appex; sourceTree = BUILT_PRODUCTS_DIR; };'
        % products["widget"]
    )
    w(
        '\t\t%s /* SkyWatchTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = SkyWatchTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };'
        % products["tests"]
    )
    w("/* End PBXFileReference section */")
    w("")


# ---------------------------------------------------------------- build files

build_file = {}


def register_build_files(target, paths):
    for path in paths:
        build_file[(target, path)] = oid("buildfile", target, path)


register_build_files("app", APP_SOURCES + APP_RESOURCES)
register_build_files("widget", WIDGET_OWN + WIDGET_SHARED + WIDGET_RESOURCES)
register_build_files("tests", TEST_OWN + TEST_SHARED)

embed_widget_bf = oid("buildfile", "embed", "widget")


def build_file_section():
    w("/* Begin PBXBuildFile section */")
    for (target, path), ident in sorted(build_file.items(), key=lambda kv: kv[1]):
        w(
            "\t\t%s /* %s in %s */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
            % (ident, os.path.basename(path), target, file_ref[path], os.path.basename(path))
        )
    w(
        "\t\t%s /* SkyWatchWidget.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = %s /* SkyWatchWidget.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };"
        % (embed_widget_bf, products["widget"])
    )
    w("/* End PBXBuildFile section */")
    w("")


# ---------------------------------------------------------------- groups

def build_group_tree(paths):
    """Nested dict mirroring the on-disk folder structure."""
    tree = {}
    for path in paths:
        parts = path.split("/")
        node = tree
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node.setdefault("__files__", []).append(path)
    return tree


group_ids = {}
group_records = []


def emit_group(name, node, prefix):
    children = []
    for key in sorted(k for k in node if k != "__files__"):
        children.append(emit_group(key, node[key], prefix + "/" + key))
    for path in sorted(node.get("__files__", [])):
        children.append((file_ref[path], os.path.basename(path)))

    ident = oid("group", prefix)
    group_ids[prefix] = ident
    group_records.append((ident, name, children, name is not None))
    return (ident, name)


tree = build_group_tree(all_paths)
root_children = []
for key in sorted(k for k in tree if k != "__files__"):
    root_children.append(emit_group(key, tree[key], key))

products_group = oid("group", "Products")
group_records.append(
    (
        products_group,
        "Products",
        [
            (products["app"], "SkyWatch.app"),
            (products["widget"], "SkyWatchWidget.appex"),
            (products["tests"], "SkyWatchTests.xctest"),
        ],
        True,
    )
)

readme_ref = oid("fileref", "README.md")
main_group = oid("group", "__root__")
group_records.append(
    (
        main_group,
        None,
        [(readme_ref, "README.md")] + root_children + [(products_group, "Products")],
        False,
    )
)


def group_section():
    w("/* Begin PBXGroup section */")
    w(
        '\t\t%s /* README.md */ = {isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = README.md; sourceTree = "<group>"; };'
        % readme_ref
    )
    for ident, name, children, named in group_records:
        w("\t\t%s = {" % ident)
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for child_id, child_name in children:
            w("\t\t\t\t%s /* %s */," % (child_id, child_name))
        w("\t\t\t);")
        if named and name is not None:
            w('\t\t\tpath = "%s";' % name if name not in ("Products",) else "\t\t\tname = Products;")
        w('\t\t\tsourceTree = "<group>";')
        w("\t\t};")
    w("/* End PBXGroup section */")
    w("")


# ---------------------------------------------------------------- phases

phases = {
    "app_sources": oid("phase", "app", "sources"),
    "app_resources": oid("phase", "app", "resources"),
    "app_frameworks": oid("phase", "app", "frameworks"),
    "app_embed": oid("phase", "app", "embed"),
    "widget_sources": oid("phase", "widget", "sources"),
    "widget_resources": oid("phase", "widget", "resources"),
    "widget_frameworks": oid("phase", "widget", "frameworks"),
    "tests_sources": oid("phase", "tests", "sources"),
    "tests_frameworks": oid("phase", "tests", "frameworks"),
}


def sources_phase(ident, target, paths):
    w("\t\t%s /* Sources */ = {" % ident)
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for path in paths:
        w("\t\t\t\t%s /* %s in Sources */," % (build_file[(target, path)], os.path.basename(path)))
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")


def resources_phase(ident, target, paths):
    w("\t\t%s /* Resources */ = {" % ident)
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for path in paths:
        w("\t\t\t\t%s /* %s in Resources */," % (build_file[(target, path)], os.path.basename(path)))
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")


def frameworks_phase(ident):
    w("\t\t%s /* Frameworks */ = {" % ident)
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")


def phase_sections():
    w("/* Begin PBXSourcesBuildPhase section */")
    sources_phase(phases["app_sources"], "app", APP_SOURCES)
    sources_phase(phases["widget_sources"], "widget", WIDGET_OWN + WIDGET_SHARED)
    sources_phase(phases["tests_sources"], "tests", TEST_OWN + TEST_SHARED)
    w("/* End PBXSourcesBuildPhase section */")
    w("")

    w("/* Begin PBXResourcesBuildPhase section */")
    resources_phase(phases["app_resources"], "app", APP_RESOURCES)
    resources_phase(phases["widget_resources"], "widget", WIDGET_RESOURCES)
    w("/* End PBXResourcesBuildPhase section */")
    w("")

    w("/* Begin PBXFrameworksBuildPhase section */")
    frameworks_phase(phases["app_frameworks"])
    frameworks_phase(phases["widget_frameworks"])
    frameworks_phase(phases["tests_frameworks"])
    w("/* End PBXFrameworksBuildPhase section */")
    w("")

    w("/* Begin PBXCopyFilesBuildPhase section */")
    w("\t\t%s /* Embed Foundation Extensions */ = {" % phases["app_embed"])
    w("\t\t\tisa = PBXCopyFilesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w('\t\t\tdstPath = "";')
    w("\t\t\tdstSubfolderSpec = 13;")
    w("\t\t\tfiles = (")
    w("\t\t\t\t%s /* SkyWatchWidget.appex in Embed Foundation Extensions */," % embed_widget_bf)
    w("\t\t\t);")
    w('\t\t\tname = "Embed Foundation Extensions";')
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXCopyFilesBuildPhase section */")
    w("")


# ---------------------------------------------------------------- targets

targets = {
    "app": oid("target", "app"),
    "widget": oid("target", "widget"),
    "tests": oid("target", "tests"),
}
project_id = oid("project")
dependency_id = oid("dependency", "widget")
container_proxy_id = oid("containerproxy", "widget")

config_lists = {
    "project": oid("configlist", "project"),
    "app": oid("configlist", "app"),
    "widget": oid("configlist", "widget"),
    "tests": oid("configlist", "tests"),
}
configs = {
    (scope, name): oid("config", scope, name)
    for scope in ("project", "app", "widget", "tests")
    for name in ("Debug", "Release")
}


def target_section():
    w("/* Begin PBXNativeTarget section */")

    w("\t\t%s /* SkyWatch */ = {" % targets["app"])
    w("\t\t\tisa = PBXNativeTarget;")
    w('\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget "SkyWatch" */;' % config_lists["app"])
    w("\t\t\tbuildPhases = (")
    w("\t\t\t\t%s /* Sources */," % phases["app_sources"])
    w("\t\t\t\t%s /* Frameworks */," % phases["app_frameworks"])
    w("\t\t\t\t%s /* Resources */," % phases["app_resources"])
    w("\t\t\t\t%s /* Embed Foundation Extensions */," % phases["app_embed"])
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t\t%s /* PBXTargetDependency */," % dependency_id)
    w("\t\t\t);")
    w("\t\t\tname = SkyWatch;")
    w("\t\t\tproductName = SkyWatch;")
    w("\t\t\tproductReference = %s /* SkyWatch.app */;" % products["app"])
    w('\t\t\tproductType = "com.apple.product-type.application";')
    w("\t\t};")

    w("\t\t%s /* SkyWatchWidget */ = {" % targets["widget"])
    w("\t\t\tisa = PBXNativeTarget;")
    w('\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget "SkyWatchWidget" */;' % config_lists["widget"])
    w("\t\t\tbuildPhases = (")
    w("\t\t\t\t%s /* Sources */," % phases["widget_sources"])
    w("\t\t\t\t%s /* Frameworks */," % phases["widget_frameworks"])
    w("\t\t\t\t%s /* Resources */," % phases["widget_resources"])
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w("\t\t\tname = SkyWatchWidget;")
    w("\t\t\tproductName = SkyWatchWidget;")
    w("\t\t\tproductReference = %s /* SkyWatchWidget.appex */;" % products["widget"])
    w('\t\t\tproductType = "com.apple.product-type.app-extension";')
    w("\t\t};")

    w("\t\t%s /* SkyWatchTests */ = {" % targets["tests"])
    w("\t\t\tisa = PBXNativeTarget;")
    w('\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget "SkyWatchTests" */;' % config_lists["tests"])
    w("\t\t\tbuildPhases = (")
    w("\t\t\t\t%s /* Sources */," % phases["tests_sources"])
    w("\t\t\t\t%s /* Frameworks */," % phases["tests_frameworks"])
    w("\t\t\t);")
    w("\t\t\tbuildRules = (")
    w("\t\t\t);")
    w("\t\t\tdependencies = (")
    w("\t\t\t);")
    w("\t\t\tname = SkyWatchTests;")
    w("\t\t\tproductName = SkyWatchTests;")
    w("\t\t\tproductReference = %s /* SkyWatchTests.xctest */;" % products["tests"])
    w('\t\t\tproductType = "com.apple.product-type.bundle.unit-test";')
    w("\t\t};")

    w("/* End PBXNativeTarget section */")
    w("")

    w("/* Begin PBXTargetDependency section */")
    w("\t\t%s /* PBXTargetDependency */ = {" % dependency_id)
    w("\t\t\tisa = PBXTargetDependency;")
    w("\t\t\ttarget = %s /* SkyWatchWidget */;" % targets["widget"])
    w("\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;" % container_proxy_id)
    w("\t\t};")
    w("/* End PBXTargetDependency section */")
    w("")

    w("/* Begin PBXContainerItemProxy section */")
    w("\t\t%s /* PBXContainerItemProxy */ = {" % container_proxy_id)
    w("\t\t\tisa = PBXContainerItemProxy;")
    w("\t\t\tcontainerPortal = %s /* Project object */;" % project_id)
    w("\t\t\tproxyType = 1;")
    w("\t\t\tremoteGlobalIDString = %s;" % targets["widget"])
    w("\t\t\tremoteInfo = SkyWatchWidget;")
    w("\t\t};")
    w("/* End PBXContainerItemProxy section */")
    w("")


def project_section():
    w("/* Begin PBXProject section */")
    w("\t\t%s /* Project object */ = {" % project_id)
    w("\t\t\tisa = PBXProject;")
    w("\t\t\tattributes = {")
    w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    w("\t\t\t\tLastSwiftUpdateCheck = 2600;")
    w("\t\t\t\tLastUpgradeCheck = 2600;")
    w("\t\t\t\tTargetAttributes = {")
    for key in ("app", "widget", "tests"):
        w("\t\t\t\t\t%s = {" % targets[key])
        w("\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;")
        w("\t\t\t\t\t};")
    w("\t\t\t\t};")
    w("\t\t\t};")
    w('\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject "SkyWatch" */;' % config_lists["project"])
    w('\t\t\tcompatibilityVersion = "Xcode 15.0";')
    w("\t\t\tdevelopmentRegion = en;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (")
    w("\t\t\t\ten,")
    w("\t\t\t\tBase,")
    w("\t\t\t);")
    w("\t\t\tmainGroup = %s;" % main_group)
    w("\t\t\tproductRefGroup = %s /* Products */;" % products_group)
    w('\t\t\tprojectDirPath = "";')
    w('\t\t\tprojectRoot = "";')
    w("\t\t\ttargets = (")
    w("\t\t\t\t%s /* SkyWatch */," % targets["app"])
    w("\t\t\t\t%s /* SkyWatchWidget */," % targets["widget"])
    w("\t\t\t\t%s /* SkyWatchTests */," % targets["tests"])
    w("\t\t\t);")
    w("\t\t};")
    w("/* End PBXProject section */")
    w("")


# ---------------------------------------------------------------- settings

COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
    "GCC_WARN_UNUSED_FUNCTION": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MTL_FAST_MATH": "YES",
    "SDKROOT": "watchos",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_VERSION": "6.0",
    "TARGETED_DEVICE_FAMILY": "4",
    "WATCHOS_DEPLOYMENT_TARGET": DEPLOYMENT,
    # Warnings are the point of a hand-written project: nothing is suppressed.
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "NO",
}

DEBUG_ONLY = {
    "COPY_PHASE_STRIP": "NO",
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)',
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
    "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
}

RELEASE_ONLY = {
    "COPY_PHASE_STRIP": "NO",
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "VALIDATE_PRODUCT": "YES",
}

APP_SETTINGS = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_ENTITLEMENTS": "SkyWatch/SkyWatch.entitlements",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "DEVELOPMENT_ASSET_PATHS": '"\\"SkyWatch/Preview Content\\""',
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "SkyWatch/Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "SkyWatch",
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ROOT,
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "NO",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}

WIDGET_SETTINGS = {
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME": "WidgetBackground",
    "CODE_SIGN_ENTITLEMENTS": "SkyWatchWidget/SkyWatchWidget.entitlements",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "SkyWatchWidget/Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "SkyWatch",
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ROOT + ".widget",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}

TEST_SETTINGS = {
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": "1.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ROOT + ".tests",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "NO",
}


def emit_config(ident, name, settings):
    w("\t\t%s /* %s */ = {" % (ident, name))
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    for key in sorted(settings):
        w("\t\t\t\t%s = %s;" % (key, settings[key]))
    w("\t\t\t};")
    w("\t\t\tname = %s;" % name)
    w("\t\t};")


def config_section():
    w("/* Begin XCBuildConfiguration section */")

    project_debug = dict(COMMON)
    project_debug.update(DEBUG_ONLY)
    project_release = dict(COMMON)
    project_release.update(RELEASE_ONLY)
    emit_config(configs[("project", "Debug")], "Debug", project_debug)
    emit_config(configs[("project", "Release")], "Release", project_release)

    for scope, settings in (("app", APP_SETTINGS), ("widget", WIDGET_SETTINGS), ("tests", TEST_SETTINGS)):
        emit_config(configs[(scope, "Debug")], "Debug", settings)
        emit_config(configs[(scope, "Release")], "Release", settings)

    w("/* End XCBuildConfiguration section */")
    w("")

    w("/* Begin XCConfigurationList section */")
    for scope, label in (
        ("project", 'PBXProject "SkyWatch"'),
        ("app", 'PBXNativeTarget "SkyWatch"'),
        ("widget", 'PBXNativeTarget "SkyWatchWidget"'),
        ("tests", 'PBXNativeTarget "SkyWatchTests"'),
    ):
        w("\t\t%s /* Build configuration list for %s */ = {" % (config_lists[scope], label))
        w("\t\t\tisa = XCConfigurationList;")
        w("\t\t\tbuildConfigurations = (")
        w("\t\t\t\t%s /* Debug */," % configs[(scope, "Debug")])
        w("\t\t\t\t%s /* Release */," % configs[(scope, "Release")])
        w("\t\t\t);")
        w("\t\t\tdefaultConfigurationIsVisible = 0;")
        w("\t\t\tdefaultConfigurationName = Release;")
        w("\t\t};")
    w("/* End XCConfigurationList section */")
    w("")


# ---------------------------------------------------------------- assemble

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {")
w("")
build_file_section()
w("/* Begin PBXCopyFilesBuildPhase, PBXFileReference and PBXGroup sections follow */")
w("")
file_reference_section()
group_section()
phase_sections()
target_section()
project_section()
config_section()
w("\t};")
w("\trootObject = %s /* Project object */;" % project_id)
w("}")

out_dir = os.path.join(ROOT, "SkyWatch.xcodeproj")
os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "project.pbxproj"), "w") as handle:
    handle.write("\n".join(lines) + "\n")

# ---------------------------------------------------------------- scheme

scheme_dir = os.path.join(out_dir, "xcshareddata", "xcschemes")
os.makedirs(scheme_dir, exist_ok=True)
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{targets['app']}"
               BuildableName = "SkyWatch.app"
               BlueprintName = "SkyWatch"
               ReferencedContainer = "container:SkyWatch.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{targets['tests']}"
               BuildableName = "SkyWatchTests.xctest"
               BlueprintName = "SkyWatchTests"
               ReferencedContainer = "container:SkyWatch.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{targets['app']}"
            BuildableName = "SkyWatch.app"
            BlueprintName = "SkyWatch"
            ReferencedContainer = "container:SkyWatch.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{targets['app']}"
            BuildableName = "SkyWatch.app"
            BlueprintName = "SkyWatch"
            ReferencedContainer = "container:SkyWatch.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
with open(os.path.join(scheme_dir, "SkyWatch.xcscheme"), "w") as handle:
    handle.write(scheme)

print("app sources:", len(APP_SOURCES))
print("widget sources:", len(WIDGET_OWN) + len(WIDGET_SHARED))
print("test sources:", len(TEST_OWN) + len(TEST_SHARED))
print("wrote", os.path.join(out_dir, "project.pbxproj"))

from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1]
swift_files = sorted((root / 'Swift').glob('*.swift'))

def uid(label: str) -> str:
    return hashlib.sha1(label.encode()).hexdigest()[:24].upper()

proj = uid('PBXProject')
target = uid('PBXNativeTarget')
main_group = uid('MainGroup')
swift_group = uid('SwiftGroup')
assets_group = uid('AssetsGroup')
frameworks_group = uid('FrameworksGroup')
products_group = uid('ProductsGroup')
product_file = uid('VXTube.app')
info_file = uid('Info.plist')
assets_file = uid('Assets.xcassets')
assets_build_file = uid('AssetsCatalogBuildFile')
sources_phase = uid('SourcesPhase')
frameworks_phase = uid('FrameworksPhase')
resources_phase = uid('ResourcesPhase')
project_debug = uid('ProjectDebug')
project_release = uid('ProjectRelease')
target_debug = uid('TargetDebug')
target_release = uid('TargetRelease')
package = uid('SwiftSoupPackage')
package_product = uid('SwiftSoupProduct')
package_build_file = uid('SwiftSoupBuildFile')

file_refs = []
build_files = []
for p in swift_files:
    name = p.name
    ref = uid('file:' + name)
    build = uid('build:' + name)
    file_refs.append((name, ref))
    build_files.append((name, ref, build))

lines = []
add = lines.append
add('// !$*UTF8*$!')
add('{')
add('\tarchiveVersion = 1;')
add('\tclasses = {')
add('\t};')
add('\tobjectVersion = 56;')
add('\tobjects = {')
add('')
# Build files
for name, ref, build in build_files:
    add(f'\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};')
add(f'\t\t{package_build_file} /* SwiftSoup in Frameworks */ = {{isa = PBXBuildFile; productRef = {package_product} /* SwiftSoup */; }};')
add(f'\t\t{assets_build_file} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_file} /* Assets.xcassets */; }};')
add('')
# File references
for name, ref in file_refs:
    add(f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{name}"; sourceTree = "<group>"; }};')
add(f'\t\t{info_file} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
add(f'\t\t{assets_file} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
add(f'\t\t{product_file} /* VXTube.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = VXTube.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
add('')
# Groups
swift_children = ', '.join(f'{ref} /* {name} */' for name, ref in file_refs)
add(f'\t\t{swift_group} /* Swift */ = {{isa = PBXGroup; children = ( {swift_children}, ); path = Swift; sourceTree = "<group>"; }};')
add(f'\t\t{assets_group} /* Assets */ = {{isa = PBXGroup; children = ( {assets_file} /* Assets.xcassets */, ); name = Assets; sourceTree = "<group>"; }};')
add(f'\t\t{frameworks_group} /* Frameworks */ = {{isa = PBXGroup; children = ( ); name = Frameworks; sourceTree = "<group>"; }};')
add(f'\t\t{products_group} /* Products */ = {{isa = PBXGroup; children = ( {product_file} /* VXTube.app */, ); name = Products; sourceTree = "<group>"; }};')
add(f'\t\t{main_group} = {{isa = PBXGroup; children = ( {swift_group} /* Swift */, {assets_group} /* Assets */, {info_file} /* Info.plist */, {frameworks_group} /* Frameworks */, {products_group} /* Products */, ); sourceTree = "<group>"; }};')
add('')
# Build phases
src_builds = ', '.join(f'{build} /* {name} in Sources */' for name, ref, build in build_files)
add(f'\t\t{sources_phase} /* Sources */ = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ( {src_builds}, ); runOnlyForDeploymentPostprocessing = 0; }};')
add(f'\t\t{frameworks_phase} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ( {package_build_file} /* SwiftSoup in Frameworks */, ); runOnlyForDeploymentPostprocessing = 0; }};')
add(f'\t\t{resources_phase} /* Resources */ = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ( {assets_build_file} /* Assets.xcassets in Resources */, ); runOnlyForDeploymentPostprocessing = 0; }};')
add('')
# Target
add(f'\t\t{target} /* VXTube */ = {{')
add('\t\t\tisa = PBXNativeTarget;')
add('\t\t\tbuildConfigurationList = ' + uid('TargetBuildConfigurationList') + ' /* Build configuration list for PBXNativeTarget "VXTube" */;')
add('\t\t\tbuildPhases = (')
add(f'\t\t\t\t{sources_phase} /* Sources */,')
add(f'\t\t\t\t{frameworks_phase} /* Frameworks */,')
add(f'\t\t\t\t{resources_phase} /* Resources */,')
add('\t\t\t);')
add('\t\t\tbuildRules = ( );')
add('\t\t\tdependencies = ( );')
add('\t\t\tname = VXTube;')
add('\t\t\tpackageProductDependencies = (')
add(f'\t\t\t\t{package_product} /* SwiftSoup */,')
add('\t\t\t);')
add('\t\t\tproductName = VXTube;')
add('\t\t\tproductReference = ' + product_file + ' /* VXTube.app */;')
add('\t\t\tproductType = "com.apple.product-type.application";')
add('\t\t};')
add('')
# Project
add(f'\t\t{proj} /* Project object */ = {{')
add('\t\t\tisa = PBXProject;')
add('\t\t\tattributes = {')
add('\t\t\t\tBuildIndependentTargetsInParallel = 1;')
add('\t\t\t\tLastUpgradeCheck = 1640;')
add('\t\t\t\tTargetAttributes = {')
add(f'\t\t\t\t\t{target} = {{ CreatedOnToolsVersion = 16.4; }};')
add('\t\t\t\t};')
add('\t\t\t};')
add('\t\t\tbuildConfigurationList = ' + uid('ProjectBuildConfigurationList') + ' /* Build configuration list for PBXProject "VXTube" */;')
add('\t\t\tcompatibilityVersion = "Xcode 14.0";')
add('\t\t\tdevelopmentRegion = en;')
add('\t\t\tknownRegions = ( en, Base, );')
add(f'\t\t\tmainGroup = {main_group};')
add('\t\t\tpackageReferences = (')
add(f'\t\t\t\t{package} /* XCRemoteSwiftPackageReference "SwiftSoup" */,')
add('\t\t\t);')
add(f'\t\t\tproductRefGroup = {products_group} /* Products */;')
add('\t\t\tprojectDirPath = "";')
add('\t\t\tprojectRoot = "";')
add('\t\t\ttargets = (')
add(f'\t\t\t\t{target} /* VXTube */,')
add('\t\t\t);')
add('\t\t};')
add('')
# Build settings
common_project = '''\n\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n\t\t\t\tCLANG_ENABLE_MODULES = YES;\n\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;\n\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;\n\t\t\t\tCLANG_WARN_CONSTANT_CONVERSION = YES;\n\t\t\t\tCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;\n\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;\n\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;\n\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;\n\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;\n\t\t\t\tCLANG_WARN_INFINITE_RECURSION = YES;\n\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;\n\t\t\t\tCLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;\n\t\t\t\tCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;\n\t\t\t\tCLANG_WARN_OBJC_LITERAL_CONVERSION = YES;\n\t\t\t\tCLANG_WARN_RANGE_LOOP_ANALYSIS = YES;\n\t\t\t\tCLANG_WARN_STRICT_PROTOTYPES = YES;\n\t\t\t\tCLANG_WARN_SUSPICIOUS_MOVE = YES;\n\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;\n\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;\n\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;\n\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;\n\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;\n\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;\n\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;\n\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 18.0;\n\t\t\t\tSDKROOT = iphoneos;\n\t\t\t\tSWIFT_VERSION = 5.0;\n'''
add(f'\t\t\t{project_debug} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{{common_project}\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n\t\t\t\tENABLE_TESTABILITY = YES;\n\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n\t\t\t\tONLY_ACTIVE_ARCH = YES;\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";\n\t\t\t}}; name = Debug; }};')
add(f'\t\t\t{project_release} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{{common_project}\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";\n\t\t\t\tENABLE_NS_ASSERTIONS = NO;\n\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";\n\t\t\t}}; name = Release; }};')

target_common = '''\n\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;\n\t\t\t\tCODE_SIGN_STYLE = Automatic;\n\t\t\t\tCURRENT_PROJECT_VERSION = 2;\n\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n\t\t\t\tINFOPLIST_FILE = Info.plist;\n\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 18.0;\n\t\t\t\tLD_RUNPATH_SEARCH_PATHS = ( "$(inherited)", "@executable_path/Frameworks", );\n\t\t\t\tMARKETING_VERSION = 1.1.0;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.vxtube.app;\n\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";\n\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n\t\t\t\tSWIFT_STRICT_CONCURRENCY = minimal;\n\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'''
add(f'\t\t\t{target_debug} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{{target_common}\t\t\t\tCODE_SIGN_IDENTITY = "Apple Development";\n\t\t\t\tENABLE_PREVIEWS = YES;\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";\n\t\t\t}}; name = Debug; }};')
add(f'\t\t\t{target_release} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{{target_common}\t\t\t\tCODE_SIGN_IDENTITY = "Apple Development";\n\t\t\t\tENABLE_PREVIEWS = YES;\n\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";\n\t\t\t}}; name = Release; }};')
# Configuration lists
project_list = uid('ProjectBuildConfigurationList')
target_list = uid('TargetBuildConfigurationList')
add(f'\t\t{project_list} /* Build configuration list for PBXProject "VXTube" */ = {{isa = XCConfigurationList; buildConfigurations = ( {project_debug} /* Debug */, {project_release} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
add(f'\t\t{target_list} /* Build configuration list for PBXNativeTarget "VXTube" */ = {{isa = XCConfigurationList; buildConfigurations = ( {target_debug} /* Debug */, {target_release} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
# SPM reference and product
add(f'\t\t{package} /* XCRemoteSwiftPackageReference "SwiftSoup" */ = {{isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/scinfu/SwiftSoup"; requirement = {{kind = upToNextMajorVersion; minimumVersion = 2.7.0; }}; }};')
add(f'\t\t{package_product} /* SwiftSoup */ = {{isa = XCSwiftPackageProductDependency; package = {package} /* XCRemoteSwiftPackageReference "SwiftSoup" */; productName = SwiftSoup; }};')
add('')
add('\t};')
add(f'\trootObject = {proj} /* Project object */;')
add('}')
(root / 'VXTube.xcodeproj').mkdir(exist_ok=True)
(root / 'VXTube.xcodeproj' / 'project.pbxproj').write_text('\n'.join(lines) + '\n')

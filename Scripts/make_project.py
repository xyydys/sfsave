#!/usr/bin/env python3
"""Generate a dependency-free Xcode project. Also checked into the zip."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'SymbolStudio.xcodeproj'

# JSON files copied to the app bundle root. A folder named "Resources" in the
# bundle root would make CFBundle treat the app as an old-style bundle and
# installation would fail with "Missing bundle ID".
RESOURCE_FILES = ['catalog.json', 'sample-plan.json', 'wechat-suggestions.json']

def uid(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def quote(value): return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

def main():
    sources = sorted((ROOT / 'SymbolStudio').glob('*.swift'))
    objects = []
    def add(key, text): objects.append(f'\t\t{uid(key)} = {{ {text} }};')
    def array(keys): return '(' + ', '.join(uid(k) for k in keys) + ')'
    for file in sources:
        add('ref-'+file.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(file.name)}; sourceTree = "<group>";')
        add('build-'+file.name, f'isa = PBXBuildFile; fileRef = {uid("ref-"+file.name)};')
    # A top-level "Resources" folder in an iOS bundle makes CFBundle treat it as an
    # old-style bundle and installation fails with "Missing bundle ID", so the
    # catalog is copied as a single file to the bundle root instead.
    for name in RESOURCE_FILES:
        add('resource-ref-'+name, f'isa = PBXFileReference; lastKnownFileType = text.json; name = {quote(name)}; path = {quote("Resources/"+name)}; sourceTree = "<group>";')
        add('resource-build-'+name, f'isa = PBXBuildFile; fileRef = {uid("resource-ref-"+name)};')
    add('assets-ref', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
    add('info-ref', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
    add('assets-build', f'isa = PBXBuildFile; fileRef = {uid("assets-ref")};')
    add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = SymbolStudio.app; sourceTree = BUILT_PRODUCTS_DIR;')
    add('source-group', f'isa = PBXGroup; children = {array(["ref-"+f.name for f in sources]+["resource-ref-"+n for n in RESOURCE_FILES]+["assets-ref","info-ref"])}; path = SymbolStudio; sourceTree = "<group>";')
    add('products-group', f'isa = PBXGroup; children = {array(["product"])}; name = Products; sourceTree = "<group>";')
    add('root-group', f'isa = PBXGroup; children = {array(["source-group", "products-group"])}; sourceTree = "<group>";')
    add('sources-phase', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(["build-"+f.name for f in sources])}; runOnlyForDeploymentPostprocessing = 0;')
    add('frameworks-phase', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    add('resources-phase', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(["resource-build-"+n for n in RESOURCE_FILES]+["assets-build"])}; runOnlyForDeploymentPostprocessing = 0;')
    for config in ['Debug','Release']:
        debug = config == 'Debug'
        project_settings = {
            'ALWAYS_SEARCH_USER_PATHS': 'NO', 'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES',
            'COPY_PHASE_STRIP': 'NO', 'IPHONEOS_DEPLOYMENT_TARGET': '16.0', 'SDKROOT': 'iphoneos',
            'SWIFT_VERSION': '5.0', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if debug else '-O',
            'DEBUG_INFORMATION_FORMAT': 'dwarf' if debug else 'dwarf-with-dsym',
            'ENABLE_TESTABILITY': 'YES' if debug else 'NO', 'ONLY_ACTIVE_ARCH': 'YES' if debug else 'NO',
        }
        target_settings = {
            'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'CODE_SIGN_STYLE': 'Automatic',
            'CURRENT_PROJECT_VERSION': '13', 'MARKETING_VERSION': '0.5.2', 'GENERATE_INFOPLIST_FILE': 'NO',
            'INFOPLIST_FILE': 'SymbolStudio/Info.plist', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.runyu.symbolstudio',
            'PRODUCT_NAME': '$(TARGET_NAME)', 'TARGETED_DEVICE_FAMILY': '1,2',
            'SUPPORTS_MACCATALYST': 'NO', 'SWIFT_EMIT_LOC_STRINGS': 'YES',
            'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks',
            'SWIFT_STRICT_CONCURRENCY': 'minimal',
        }
        for prefix, settings in [('project', project_settings), ('target', target_settings)]:
            settings_text = ' '.join(f'{key} = {quote(value)};' for key,value in settings.items())
            add(prefix+'-'+config, f'isa = XCBuildConfiguration; buildSettings = {{ {settings_text} }}; name = {config};')
    for prefix in ['project','target']:
        add(prefix+'-configs', f'isa = XCConfigurationList; buildConfigurations = {array([prefix+"-Debug",prefix+"-Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    add('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("target-configs")}; buildPhases = {array(["sources-phase","frameworks-phase","resources-phase"])}; buildRules = (); dependencies = (); name = SymbolStudio; productName = SymbolStudio; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
    add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (en, zh_CN, Base); mainGroup = {uid("root-group")}; productRefGroup = {uid("products-group")}; projectDirPath = ""; projectRoot = ""; targets = {array(["target"])};')
    OUT.mkdir(exist_ok=True)
    (OUT/'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n'+'\n'.join(objects)+'\n\t};\n\trootObject = '+uid('project')+';\n}\n')
    scheme = OUT/'xcshareddata/xcschemes/SymbolStudio.xcscheme'; scheme.parent.mkdir(parents=True,exist_ok=True)
    ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="SymbolStudio.app" BlueprintName="SymbolStudio" ReferencedContainer="container:SymbolStudio.xcodeproj"/>'
    scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    print('Generated',OUT.name,'with',len(sources),'Swift source files')

if __name__=='__main__': main()

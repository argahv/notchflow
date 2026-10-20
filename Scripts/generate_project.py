#!/usr/bin/env python3
"""Generate a dependency-free, deterministic Xcode project; no XcodeGen needed."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
def ident(key): return hashlib.sha256(key.encode()).hexdigest()[:24].upper()
def quote(value): return json.dumps(str(value))
def generate():
    files = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "Sources").rglob("*.swift"))
    objects = []
    def obj(key, value): objects.append(f"\t\t{ident(key)} = {{ {value} }};")
    for path in files:
        obj("file:" + path, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(path)}; sourceTree = SOURCE_ROOT;")
        obj("build:" + path, f"isa = PBXBuildFile; fileRef = {ident('file:' + path)};")
    metal = "Resources/LiquidGlass.metal"
    obj("file:" + metal, f"isa = PBXFileReference; lastKnownFileType = text; path = {quote(metal)}; sourceTree = SOURCE_ROOT;")
    obj("build:" + metal, f"isa = PBXBuildFile; fileRef = {ident('file:' + metal)};")
    obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = NotchFlow.app; sourceTree = BUILT_PRODUCTS_DIR;')
    children = ", ".join(ident("file:" + p) for p in files + [metal])
    obj("mainGroup", f'isa = PBXGroup; children = ({children}, {ident("products")}); sourceTree = "<group>";')
    obj("products", f'isa = PBXGroup; children = ({ident("product")}); name = Products; sourceTree = "<group>";')
    build_refs = ", ".join(ident("build:" + p) for p in files)
    obj("sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({build_refs}); runOnlyForDeploymentPostprocessing = 0;')
    obj("resources", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ident("build:" + metal)}); runOnlyForDeploymentPostprocessing = 0;')
    obj("frameworks", 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    for level in ("project", "target"):
        configs = []
        for mode in ("Debug", "Release"):
            key = level + mode; configs.append(ident(key))
            settings = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.6", "SWIFT_VERSION": "5.0",
                        "CLANG_ENABLE_MODULES": "YES", "SWIFT_STRICT_CONCURRENCY": "targeted"}
            if level == "target":
                settings.update({"PRODUCT_NAME": "NotchFlow", "PRODUCT_BUNDLE_IDENTIFIER": "com.argahv.notchflow",
                                 "INFOPLIST_FILE": "Resources/Info.plist", "CODE_SIGN_ENTITLEMENTS": "Resources/NotchFlow.entitlements",
                                 "CODE_SIGN_STYLE": "Automatic", "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_APP_SANDBOX": "NO",
                                 "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
                                 "SWIFT_EMIT_LOC_STRINGS": "YES", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.0",
                                 "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O"})
            if mode == "Debug":
                settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            body = " ".join(f"{k} = {quote(v)};" for k,v in settings.items())
            obj(key, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {mode};')
        obj(level + "configs", f'isa = XCConfigurationList; buildConfigurations = ({", ".join(configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    obj("target", f'isa = PBXNativeTarget; buildConfigurationList = {ident("targetconfigs")}; buildPhases = ({ident("sources")}, {ident("frameworks")}, {ident("resources")}); buildRules = (); dependencies = (); name = NotchFlow; productName = NotchFlow; productReference = {ident("product")}; productType = "com.apple.product-type.application";')
    obj("project", f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {ident("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {ident("mainGroup")}; productRefGroup = {ident("products")}; projectDirPath = ""; projectRoot = ""; targets = ({ident("target")});')
    project = ROOT / "NotchFlow.xcodeproj"
    project.mkdir(exist_ok=True)
    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {ident('project')};\n}}\n")
    schemes = project / "xcshareddata/xcschemes"; schemes.mkdir(parents=True, exist_ok=True)
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="NotchFlow.app" BlueprintName="NotchFlow" ReferencedContainer="container:NotchFlow.xcodeproj"/>'
    (schemes / "NotchFlow.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    print(f"Generated {project.name} with {len(files)} Swift sources")

if __name__ == "__main__": generate()

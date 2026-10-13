"""project.ymlの版と表示設定から、ローカルビルドのInfo.plistを作る。"""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
project = (root / "project.yml").read_text(encoding="utf-8")
def setting(name):
    return re.search(r'^\s*' + name + r': "([^"]+)"', project, re.M)[1]

info = {
    "CFBundleDisplayName": "Komiflo",
    "CFBundleShortVersionString": setting("MARKETING_VERSION"),
    "CFBundleVersion": setting("CURRENT_PROJECT_VERSION"),
    "UIDeviceFamily": [1, 2],
    "LSApplicationCategoryType": "public.app-category.books",
    "UIApplicationSupportsIndirectInputEvents": True,
    "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
    "UILaunchScreen": {},
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait",
                                         "UIInterfaceOrientationLandscapeLeft",
                                         "UIInterfaceOrientationLandscapeRight"],
    # iPadは4方向と分割表示に対応する。
    "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait",
                                              "UIInterfaceOrientationPortraitUpsideDown",
                                              "UIInterfaceOrientationLandscapeLeft",
                                              "UIInterfaceOrientationLandscapeRight"],
}
destination = root / "LocalBuild" / "Info.plist"
destination.parent.mkdir(exist_ok=True)
destination.write_bytes(plistlib.dumps(info))
print(destination)

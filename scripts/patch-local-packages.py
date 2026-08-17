#!/usr/bin/env python3
"""Run after `xcodegen generate`.

Only needed when RainSDK is consumed from a local checkout: XcodeGen emits local Swift
packages as plain folder references, which xcodebuild (Xcode 26) ignores. Rewrites the
generated pbxproj with a proper XCLocalSwiftPackageReference entry. No-ops when RainSDK
is resolved from its git URL, which is the default.
"""

import os
import re
import sys

PBXPROJ = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "RainAgentDemo.xcodeproj",
    "project.pbxproj",
)

SDK_REF = "AA10000000000000000000C0"
SDK_PATH = "../rain-sdk-ios"
PRODUCTS = ("rain-core-ios", "rain-privy-ios")


def main() -> None:
    with open(PBXPROJ) as f:
        src = f.read()

    if "XCLocalSwiftPackageReference" in src:
        print("already patched")
        return

    if "rain-sdk-ios.git" in src:
        print("RainSDK resolves from git; nothing to patch")
        return

    local_section = f"""/* Begin XCLocalSwiftPackageReference section */
\t\t{SDK_REF} /* XCLocalSwiftPackageReference "{SDK_PATH}" */ = {{
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = "{SDK_PATH}";
\t\t}};
/* End XCLocalSwiftPackageReference section */"""

    marker = "/* Begin XCRemoteSwiftPackageReference section */"
    if marker not in src:
        sys.exit("marker not found; pbxproj layout changed")
    src = src.replace(marker, local_section + "\n\n" + marker, 1)

    pkg_refs = "packageReferences = (\n"
    if pkg_refs not in src:
        sys.exit("packageReferences not found; pbxproj layout changed")
    src = src.replace(
        pkg_refs,
        pkg_refs + f'\t\t\t\t{SDK_REF} /* XCLocalSwiftPackageReference "{SDK_PATH}" */,\n',
        1,
    )

    # Product names contain dashes, so XcodeGen may or may not quote them.
    for product in PRODUCTS:
        pattern = re.compile(
            r'isa = XCSwiftPackageProductDependency;\n\t\t\tproductName = "?'
            + re.escape(product)
            + r'"?;'
        )
        replacement = (
            "isa = XCSwiftPackageProductDependency;\n"
            f'\t\t\tpackage = {SDK_REF} /* XCLocalSwiftPackageReference "{SDK_PATH}" */;\n'
            f'\t\t\tproductName = "{product}";'
        )
        src, n = pattern.subn(replacement, src, count=1)
        if n == 0:
            sys.exit(f"product dependency for '{product}' not found; pbxproj layout changed")

    with open(PBXPROJ, "w") as f:
        f.write(src)
    print("patched", PBXPROJ)


if __name__ == "__main__":
    main()

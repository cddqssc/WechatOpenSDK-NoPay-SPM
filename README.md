# WechatOpenSDK-NoPay-SPM

这是微信[openSDK](https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Downloads/iOS_Resource.html)的 Swift Package Manager包装仓库。

项目核心是保持官方 `WechatOpenSDK-NoPay.xcframework` 不变，并额外生成一个真正的 dynamic xcframework：

```text
WechatOpenSDK-NoPay-Dynamic.xcframework
```

`Package.swift` 当前指向这个 dynamic 产物。

## 背景

腾讯官方提供的 `WechatOpenSDK-NoPay.xcframework` 外观看起来是 framework/xcframework，但其中的 `WechatOpenSDK.framework/WechatOpenSDK` 实际上是一个 static archive。

在部分 Flutter + SwiftPM + Xcode 构建链路里，如果直接把这个 static framework 作为 SwiftPM binary target 使用，Xcode/SPM 会在 App 构建时重新包装出一个嵌入到 App 里的动态 framework：

```text
Runner.app/Frameworks/WechatOpenSDK.framework
```

问题在于，这个重新包装出来的 Mach-O binary 里的 `LC_BUILD_VERSION` 可能会被写成主 App 的 Deployment Target，例如 iOS 15.0；但 framework 自己的 `Info.plist` 仍然来自腾讯原始 SDK，里面的 `MinimumOSVersion` 是 iOS 12.0。

这会导致二者不一致：

```text
Info.plist MinimumOSVersion = 12.0
Mach-O LC_BUILD_VERSION minos = 15.0
```

App Store 上传时可能因此报错：

```text
ITMS-90208: Invalid Bundle - The bundle Runner.app/Frameworks/WechatOpenSDK.framework does not support the minimum OS Version specified in the Info.plist.
```

**腾讯原始 `Info.plist` 中的 iOS 12.0 才是这个 SDK 声明的真实最低系统版本；iOS 15.0 是本地 App 构建配置在重新包装时带来的结果。**

## 解决方案

本仓库不修改腾讯官方原始 SDK，而是在仓库内额外维护一个生成脚本：

```sh
scripts/build_dynamic_xcframework.sh
```

该脚本会：

1. 读取腾讯原始 `WechatOpenSDK-NoPay.xcframework`
2. 从其中取出 真机 和 模拟器 的 static framework binary
3. 使用 `clang -dynamiclib` 将 static archive 重新链接成真正的 dynamic framework
4. 使用 `vtool` 将 Mach-O 的 `LC_BUILD_VERSION` 统一设置为 iOS 12.0（与腾讯原始 `Info.plist`保持一致）
5. 复制原始 Headers、Modules、Info.plist 和 PrivacyInfo.xcprivacy
6. 使用 `xcodebuild -create-xcframework` 生成 `WechatOpenSDK-NoPay-Dynamic.xcframework`

最终生成的 dynamic framework 同时满足：

```text
Info.plist MinimumOSVersion = 12.0
Mach-O LC_BUILD_VERSION minos = 12.0
```

这样 Xcode/SPM 后续消费的是已经生成好的 dynamic xcframework，不再需要在 App 构建阶段把腾讯 static framework 重新包装成一个新的 dynamic framework。

## 仓库结构

```text
Package.swift
WechatOpenSDK-NoPay.xcframework - 腾讯官方提供的原始 SDK，无任何修改
WechatOpenSDK-NoPay-Dynamic.xcframework - 由脚本生成的 dynamic 产物，SwiftPM 实际使用它。
scripts/build_dynamic_xcframework.sh - 重新生成 dynamic xcframework 的脚本。
```

## 如何重新生成 Dynamic XCFramework

如果腾讯官方更新了 WechatOpenSDK-NoPay：

1. 替换仓库中的原始 SDK：

   ```text
   WechatOpenSDK-NoPay.xcframework
   ```

2. 重新运行脚本：（如果腾讯在未来的版本修改了`Info.plist` 中的最低 ios版本，需要在脚本中同步修改，目前是12.0）

   ```sh
   ./scripts/build_dynamic_xcframework.sh
   ```

3. 检查生成产物：

   ```sh
   file WechatOpenSDK-NoPay-Dynamic.xcframework/ios-arm64/WechatOpenSDK.framework/WechatOpenSDK
   xcrun vtool -show-build WechatOpenSDK-NoPay-Dynamic.xcframework/ios-arm64/WechatOpenSDK.framework/WechatOpenSDK
   /usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' WechatOpenSDK-NoPay-Dynamic.xcframework/ios-arm64/WechatOpenSDK.framework/Info.plist
   xcrun otool -L WechatOpenSDK-NoPay-Dynamic.xcframework/ios-arm64/WechatOpenSDK.framework/WechatOpenSDK
   ```

期望结果：

```text
Mach-O 64-bit dynamically linked shared library arm64
LC_BUILD_VERSION platform IOS minos 12.0
MinimumOSVersion = 12.0
```

## 链接依赖是如何确定的

脚本中的系统 framework/library 依赖不是猜的，而是通过查看腾讯 static archive 的 undefined symbols 推断：

```sh
xcrun nm -u WechatOpenSDK-NoPay.xcframework/ios-arm64/WechatOpenSDK.framework/WechatOpenSDK
```

当前最小链接集合为：

```sh
-framework Foundation
-framework UIKit
-framework CoreGraphics
-framework Security
-framework WebKit
-lc++
```

对应关系大致如下：

- `Foundation`：`NSString`、`NSData`、`NSURL`、`NSDictionary`、`NSJSONSerialization` 等符号。
- `UIKit`：`UIApplication`、`UIScreen`、`UIViewController`、`UIImage`、`UIImageJPEGRepresentation` 等符号。
- `CoreGraphics`：`CGSizeZero` 等 CG 符号。
- `Security`：`SecItemAdd`、`SecItemCopyMatching`、`SecItemDelete` 等 Keychain 符号。
- `WebKit`：`WKWebView`、`WKWebViewConfiguration` 等符号。
- `libc++`：`__ZSt9terminatev`、`___cxa_begin_catch`、`___gxx_personality_v0` 等 C++ runtime 符号。

如果未来腾讯 SDK 更新后脚本链接失败，通常会出现 `Undefined symbols`。此时应根据报错符号判断是否需要新增系统 framework 或系统 library。

# MacRunAsDate — RunAsDate for Mac

让某个程序以指定的日期时间运行，系统时钟不受影响。这是面向 macOS 的 RunAsDate 功能实现，界面和选项参考 NirSoft RunAsDate，属于非官方独立项目。

Mac version of RunAsDate: launch an application with a specified date and time without changing the system clock. An independent, unofficial macOS implementation inspired by NirSoft RunAsDate.

支持 macOS 13.0 及以上版本，构建产物同时包含 Apple Silicon（arm64）和 Intel（x86_64）架构。

## 构建

需要 Xcode 或 Command Line Tools（`xcode-select --install`）。

```bash
./build.sh
```

产物：`build/MacRunAsDate.app`（可拖进“应用程序”），以及测试程序 `build/timecheck`。

## 打包与安装

```bash
zsh package.sh
```

在 `dist/` 下生成 `MacRunAsDate-<版本号>.dmg` 和 `MacRunAsDate-<版本号>.zip`。打开 DMG，把 MacRunAsDate 拖进“应用程序”即可。

本程序只做了 ad-hoc 签名，没有 Apple 公证。从网上或聊天工具传到另一台 Mac 后，第一次打开会被拦截：到“系统设置 → 隐私与安全性”底部点“仍要打开”。也可以在终端解除隔离：

```bash
xattr -dr com.apple.quarantine /Applications/MacRunAsDate.app
```

## 原理

`libfaketime.dylib` 通过 `DYLD_INSERT_LIBRARIES` 注入目标进程，用 dyld interpose 替换以下函数：

- `time`
- `gettimeofday`
- `clock_gettime(CLOCK_REALTIME)`
- `clock_gettime_nsec_np(CLOCK_REALTIME)`
- `CFAbsoluteTimeGetCurrent`（即 NSDate / Swift `Date()`）

单调时钟（`mach_absolute_time`、`CLOCK_MONOTONIC`）不做修改，所以程序里的计时器和动画仍然正常。目标程序启动的子进程会继承同一个伪造时间。

## 使用说明

- 选择 `.app` 时，点“运行”会直接启动它。
- 选择命令行程序时，点“运行”会在“终端”窗口里运行，能看到它的输出，第一行会显示伪造的时间。
- 界面上的设置会自动保存，下次打开时恢复。

## 与 Windows 版选项的对应

| RunAsDate | MacRunAsDate |
|---|---|
| Absolute / Relative date | 绝对日期/时间 / 相对当前时间 |
| Move the time forward… | 时间按真实时间向前流逝 |
| Return to the current date/time after… | 在以下秒数后恢复为当前真实时间 |
| Create Desktop Shortcut | 在桌面生成 `.command` 脚本，双击运行 |
| Immediate Mode | 不需要：dyld 注入本身就在程序启动前生效 |
| Attach To Process | 不支持：macOS 不允许向已运行的进程注入 |
| Run As Administrator | 不提供 |

## 限制（macOS 安全机制导致）

以下程序会忽略注入，时间不会改变。程序会在启动时检测这些情况并给出提示：

1. **Apple 系统程序**：`/System`、`/usr/bin` 下的程序和 Apple 自带的 App，受 SIP 保护。
2. **启用 Hardened Runtime 的程序**：除非它带有 `com.apple.security.cs.allow-dyld-environment-variables` 授权。大多数经过公证（notarized）的第三方 App 都属于这一类。
3. **启用库验证的程序**：除非它带有 `com.apple.security.cs.disable-library-validation` 授权。

对于第 2、3 类程序，可以点界面左下角的“创建可注入副本…”。它会把程序复制到 `~/Library/Application Support/MacRunAsDate/Copies/`，去掉隔离属性，再用本机临时签名重新签名（不带 Hardened Runtime 和授权），然后自动改用这个副本。原程序不受影响。代价是副本会失去钥匙串、iCloud、推送等需要授权的功能，个别会自检签名的程序可能打不开。请只对你有权这样使用的软件操作。

另外，程序如果通过网络校时或读取服务器时间，本工具也无法改变它看到的时间。

## 命令行用法

不用界面也可以直接在终端里用：

```bash
DYLD_INSERT_LIBRARIES="$PWD/build/MacRunAsDate.app/Contents/Resources/libfaketime.dylib" RAD_TIME=$(date -j -f "%Y-%m-%d %H:%M:%S" "2020-01-01 08:00:00" +%s) ./build/timecheck
```

可用的环境变量：

- `RAD_TIME`：伪造的时间，Unix 时间戳（秒）。
- `RAD_FREEZE=1`：时间冻结，不随真实时间流逝。
- `RAD_RETURN_AFTER=N`：N 秒后恢复真实时间。

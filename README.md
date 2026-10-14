<p align="center">
  <img src="docs/media/banner.svg" alt="rayneo-io-on-mac: boot your own RayNeo iO firmware on a Mac, in Renode" width="100%">
</p>

<p align="center">
  <b>A full-system emulator experiment for RayNeo iO smart glasses, running on your Mac.</b><br>
  A Renode board model plus a native Swift viewer, aimed at booting the <i>unmodified</i> stock firmware and showing its real display output.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-22E05A?style=flat-square"></a>
  <img alt="Status: experimental" src="https://img.shields.io/badge/status-experimental-orange?style=flat-square">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-2E8BFF?style=flat-square">
  <img alt="Built on Renode" src="https://img.shields.io/badge/built%20on-Renode-6E40C9?style=flat-square">
  <img alt="Unofficial" src="https://img.shields.io/badge/unofficial-not%20affiliated%20with%20RayNeo-555?style=flat-square">
</p>

<p align="center">
  <a href="#status">Status</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#roadmap">Roadmap</a> ·
  <a href="#how-to-help">How to help</a> ·
  <a href="#中文">中文</a>
</p>

> [!IMPORTANT]
> **No firmware is distributed here.** You must bring your own. This is an unofficial project and is not affiliated with or endorsed by RayNeo, Bestechnic or any other vendor. It only emulates on a computer and never flashes hardware.

## Why

Developing for smart glasses usually means flashing a real device for every change, with a real chance of bricking it. A faithful emulator changes that:

- **Iterate safely.** Boot the firmware you already own on your laptop, as many times as you like.
- **Learn the hardware honestly.** Every peripheral model is written from what the firmware actually does on the emulated bus, not from guesses dressed up as results.
- **No patched instructions.** The goal is to run the stock image as-is. When something fails, we fix the model, not the firmware.

## Status

This is an **experiment, not a finished emulator.** It does not reach a usable home screen yet.

<p align="center">
  <img src="docs/media/boot-progress.svg" alt="Boot progress: the stock firmware loads, enters NuttX, runs board init, mounts storage and shows its boot logo; it stops when the AP opens the BTH subsystem" width="100%">
</p>

| Area | State | Notes |
|---|---|---|
| AP core boots NuttX | Working | Unmodified AP firmware enters the NuttX kernel and completes the board init calls we have observed |
| Boot logo in the Mac window | Working | The display controller model scans out memory the firmware actually wrote; the window shows that frame |
| BTC controller | Working | Its code executes on the emulated CPU |
| Storage (NOR, NAND, PSRAM, DMA) | Initial model | Firmware formats and mounts the emulated NAND (in-memory, fresh each boot); data path checked by `scripts/check-storage.py` |
| Board I/O (GPIO, SPI, I2C, panel, LCD DMA) | Initial model | Enough for boot; panel checked by `scripts/check-panel.py` |
| BTH subsystem | **In progress** | Boot stops when the AP opens BTH, because it needs BTH in its *installed* flash format. An installed-image builder and a BTH board model are being brought up |
| GPU | Partial | Init registers only; no draw commands executed, and it never fakes completion |
| Other cores, IPC, resource filesystem, input | Not started | |
| Calibration | Unverified | Several register, ID and clock values are inferred from firmware, not measured on hardware |
| Packaging | Not yet | Verified only on the author's Mac; not a portable app |

The detailed engineering log lives in [`docs/DEV-NOTES.md`](docs/DEV-NOTES.md).

## Quick start

Requirements: macOS 14 or later, Xcode command line tools, Python 3, and [Renode](https://renode.io) (MIT licensed, installed separately, **not bundled**).

```sh
git clone https://github.com/owenc1122/rayneo-io-on-mac.git && cd rayneo-io-on-mac

# 1. Renode: put it at .local/renode/Renode.app, or export RENODE=/path/to/renode
# 2. Your firmware: .local/firmware.bin (AP image), or an extracted OTA file set

swift test                                   # unit tests
sh scripts/build-app.sh                      # builds "build/RayNeo io on Mac.app" (local ad-hoc signature)
sh scripts/run-app.sh                        # boots .local/firmware.bin and shows the display
sh scripts/emulate.sh <ota-files-dir> 15     # headless run, 15 s of emulated time
```

Each run writes `boot.log` and the received `frame.pgm` under `.local/runs/` (git-ignored). The app shows only frames produced by the current run; it never loads stored screenshots.

### Bring your own firmware

No vendor firmware, OTA package, or images and assets extracted from them are included. Get the Strix OS files from your own device or another lawful source and keep them under `.local/` (git-ignored): the AP image as `.local/firmware.bin`, or pass an extracted OTA file set (with `OtaFileInfo.json`) to `scripts/emulate.sh`. The scripts only read these files and never modify them.

## Architecture

<p align="center">
  <img src="docs/media/architecture.svg" alt="Architecture: your firmware and scripts feed a Renode BES1700 board model; the LCDC frame buffer is shown by the Swift Mac viewer" width="100%">
</p>

| Path | What lives there |
|---|---|
| [`platform/`](platform/) | Renode board description (`best1700.repl`) and C# peripheral models (`peripherals/*.cs`) |
| [`scripts/`](scripts/) | App build and launch, headless emulation, installed flash image builder, peripheral checks |
| [`Sources/RayNeoSimulator/`](Sources/RayNeoSimulator/) | Swift macOS app: starts the Renode run and displays completed scan-outs |
| [`Tests/`](Tests/) | Swift unit tests and Renode storage test scripts |

## Roadmap

- [x] AP boots NuttX on the emulated CPU, unmodified
- [x] Display scan-out to a native Mac window (boot logo)
- [x] Storage and DMA data path with automated checks
- [ ] **BTH bring-up**: installed-format flash image, BTH reset entry, address aliases
- [ ] AP and BTH inter-processor communication
- [ ] Resource filesystem and a boot that gets past the logo
- [ ] GPU draw commands
- [ ] Crown and button input from the Mac keyboard and trackpad
- [ ] Dual-panel layout and full display formats
- [ ] Portable, signed app bundle

## How to help

This project moves fastest with people who know embedded hardware, Renode or NuttX.

- **Peripheral models.** Pick an unimplemented block, read what the firmware does with it in a trace, and model that behaviour in `platform/peripherals/`.
- **Hardware measurements.** If you own the glasses and can read real register, ID or clock values without modifying the device, they can replace our inferred assumptions.
- **Tests.** Every model should come with a check script that fails loudly when behaviour regresses.
- **Reports.** Open an issue with your macOS version, Renode version and the tail of `boot.log`. Do **not** attach firmware, extracted images or screenshots of the firmware's own output.

Keep contributions original: no vendor code, binaries or assets, and no code ported from other projects whose license or origin is unclear.

## License

Original code is released under the [MIT License](LICENSE). Renode is MIT licensed and installed separately by the user; it is not bundled. Firmware and its contents belong to their respective rights holders and are not covered by this license.

> **Disclaimer.** Unofficial and not affiliated with or endorsed by RayNeo, Bestechnic or any vendor; names are used only to describe what this interoperates with. This project only emulates on a computer and never flashes hardware. Applying anything learned here to a real device can brick it, void the warranty or breach vendor terms, at your own risk. Provided "as is", without warranty of any kind.

---

## 中文

**雷鸟 iO（RayNeo iO）眼镜的整机模拟器实验，跑在你的 Mac 上。** 基于 [Renode](https://renode.io) 的 BES1700 板级模型 + Swift 原生窗口，目标是运行**原版、未修改指令的**固件，并显示它真实的画面输出。

> **本仓库不分发任何固件，需自备。** 本项目为非官方项目，与雷鸟创新（RayNeo）、Bestechnic 或任何厂商无关联、未获认可；只在电脑上模拟，从不刷写设备。

### 当前进度（如实说明）

**整机模拟器尚未完成，还不能进入可操作的桌面。**

| 部分 | 状态 | 说明 |
|---|---|---|
| AP 启动 NuttX | 可用 | 未改指令的 AP 固件进入 NuttX 内核，完成已观察到的板级初始化 |
| Mac 窗口显示开机标志 | 可用 | 显示控制器读取固件实际写入的内存，窗口显示该帧 |
| BTC 控制器 | 可用 | 代码在模拟 CPU 上执行 |
| 存储（NOR/NAND/PSRAM/DMA） | 初步模型 | 固件能格式化并挂载模拟 NAND（仅内存、每次重新创建），`scripts/check-storage.py` 验证 |
| 板级 I/O（GPIO/SPI/I2C/屏幕/LCD DMA） | 初步模型 | 满足启动所需，`scripts/check-panel.py` 验证屏幕 |
| BTH 子系统 | **进行中** | AP 打开 BTH 时需要**已安装格式**的 BTH 镜像，启动在此停止；已安装镜像生成器和 BTH 板级模型正在调试 |
| GPU | 部分 | 只模拟初始化寄存器，不执行绘制，也不会假报完成 |
| 其他核、核间通信、资源文件系统、输入 | 未开始 | |
| 校准 | 未验证 | 多处寄存器、ID、时钟值从固件推断，未经实机测量 |
| 打包 | 暂无 | 只在作者本机验证，尚非可移植应用 |

详细开发记录见 [`docs/DEV-NOTES.md`](docs/DEV-NOTES.md)。

### 快速开始

需要 macOS 14+、Xcode 命令行工具、Python 3，以及另行安装的 Renode（MIT，**不随仓库分发**）。

```sh
# Renode 放到 .local/renode/Renode.app，或设置 RENODE=/path/to/renode
# 固件：.local/firmware.bin（AP 镜像），或解出的 OTA 文件集目录
swift test
sh scripts/build-app.sh
sh scripts/run-app.sh
sh scripts/emulate.sh <OTA 文件目录> 15
```

运行记录（`boot.log`、`frame.pgm`）写入 `.local/runs/`（已忽略）。应用只显示本次运行产生的帧，不载入历史截图。

### 自备固件

本仓库**不包含**任何厂商固件、OTA 包或从中提取的镜像与图片。请从你自己的设备或其他合法渠道取得 Strix OS 固件，放在 `.local/`（已 gitignore）。脚本只读取这些文件，不做任何修改。

### 架构与路线图

启动进度见上方 [Status](#status) 图，架构图见 [Architecture](#architecture)。下一步依次是：BTH 已安装镜像与复位入口、AP 与 BTH 核间通信、资源文件系统并越过开机标志、GPU 绘制、键盘/触控板映射为表冠输入、双屏布局、可移植签名应用。

### 如何参与

欢迎熟悉嵌入式、Renode 或 NuttX 的朋友：补外设模型、提供（不改设备即可读取的）实机寄存器测量值、为模型写检查脚本、报告运行结果。提 issue 时请附 macOS / Renode 版本和 `boot.log` 末尾，**不要**附固件、提取的镜像或固件画面截图。贡献须为原创。

### 许可与免责

原创代码采用 [MIT](LICENSE)。Renode 采用 MIT 许可，由使用者自行安装。固件及其内容归各自权利人所有，不在本许可范围内。

> **免责声明。** 本项目为非官方项目，名称仅用于说明互操作对象。本项目只在电脑上模拟，不刷写设备；若你把从中获得的知识用于修改或刷写实体设备，可能导致变砖、失去保修或违反厂商条款，风险自负。软件按“原样”提供，不附带任何担保。

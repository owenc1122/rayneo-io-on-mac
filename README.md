<p align="center">
  <img src="docs/media/banner.svg" alt="rayneo-io-on-mac: a macOS viewer for a RayNeo iO full-system emulator" width="100%">
</p>

<p align="center">
  <b>The native macOS viewer for a full-system emulator of RayNeo iO smart glasses.</b><br>
  This repository holds the app shell and architecture. The emulation core it drives — the board
  model, the device models and the companion-phone side — is proprietary and is <i>not</i> included here.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT (shell)" src="https://img.shields.io/badge/license-MIT%20(shell)-22E05A?style=flat-square"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-2E8BFF?style=flat-square">
  <img alt="Core: proprietary" src="https://img.shields.io/badge/emulation%20core-proprietary-555?style=flat-square">
  <img alt="Unofficial" src="https://img.shields.io/badge/unofficial-not%20affiliated%20with%20RayNeo-555?style=flat-square">
</p>

> [!IMPORTANT]
> **Open shell, closed core.** What is published here is the macOS viewer application and the
> high-level architecture. The parts that embody the reverse engineering of the glasses — the Renode
> board description and peripheral device models, the Bluetooth stack and pairing, the companion-phone
> protocol, the flash/boot image construction and the test suite — are a proprietary core that is kept
> private and is not distributed. This repository on its own does not run a full emulation.
>
> **No firmware is distributed here either.** This is an unofficial project, not affiliated with or
> endorsed by RayNeo, Bestechnic or any other vendor. It only emulates on a computer and never flashes hardware.

## What this is

RayNeo iO on Mac boots the **unmodified stock glasses firmware** inside an emulator on a Mac and shows
its real display output in a native window — press the crown, record and play audio, pair a virtual
phone over Bluetooth, and see the stock launcher, dashboard, captions and apps exactly as on the device.

This repo is the **shell**: the SwiftUI window, the input menus (crown, head motion, voice) and the
glue that launches the emulator and streams its framebuffer, audio and input. The **core** that
actually models the BES1700 silicon and the companion phone is maintained separately and is not open.

<p align="center">
  <img src="docs/media/architecture.svg" alt="High-level architecture: the macOS viewer shell drives a proprietary Renode-based emulation core" width="100%">
</p>

## Architecture (high level)

- **Viewer shell (this repo).** A native macOS/SwiftUI app: it renders the two-eye display, forwards
  input (crown press/rotate, head motion, microphone, voice wake), plays firmware audio on the Mac
  speaker, and manages the emulator process. See [`Sources/RayNeoSimulator`](Sources/RayNeoSimulator).
- **Emulation core (proprietary, not included).** A Renode board model of the BES1700 (four Arm cores),
  the peripheral device models that make the stock firmware run, the Bluetooth controller and companion
  phone (BLE + classic), and the flash/boot image builders. Distributed privately.

## What the full system does

Booting to the real home screen; crown input; clock and battery; timers, I²C, GPU and the two-eye
display; audio in/out through the DSP contract with the "小雷小雷" wake word; head-up wake; and a
virtual phone over Bluetooth driving weather, to-do, live captions, notifications, the AI assistant,
the recorder, settings sync, teleprompter and OTA. Classic Bluetooth pairing, SPP (rnlink), HFP incoming-call UI and the call link work, and HFP call audio works: the controller models the baseband SCO hardware so the stock link controller runs the whole call and decoded downlink audio plays on the speaker, 0 firmware asserts. iO has no music app, so A2DP/AVRCP is SDK-only, not a feature. Speed is real-time on a patched Renode build.

## Status

Boots to the stock home screen; the viewer shows the live display and handles input. Running a full
emulation requires the proprietary core and your own firmware, neither of which is included here.

## 中文

**雷鸟 iO Mac 模拟器 —— 原生 macOS 查看器（开源表皮）。**

本仓库是**表皮**:原生 SwiftUI 窗口、输入菜单（表冠、头部动作、语音）以及启动模拟器、串流画面/音频/输入的胶水代码。真正建模 BES1700 芯片和手机端的**内核**（Renode 板级模型、各外设设备模型、蓝牙栈与配对、手机协议、闪存/启动镜像构造、测试套件）是**专有内核,单独私有维护,不随本仓库发布**。仅凭本仓库无法运行完整模拟。

> **本仓库不分发任何固件。** 本项目为非官方项目,与雷鸟创新（RayNeo）、Bestechnic 或任何厂商无关联、未获认可;只在电脑上模拟,从不刷写设备。

**整机能做什么**:进入真实桌面、表冠输入、时钟电量、定时器/I²C/GPU/双眼显示、经 DSP 接口的录放音与「小雷小雷」语音唤醒、抬头亮屏,以及虚拟手机经蓝牙驱动天气、待办、实时字幕、通知、AI 助手、录音、设置同步、提词器和 OTA。经典蓝牙配对、SPP、来电界面与通话链路已通,通话语音已通:控制器按硬件建模 SCO 射频,原厂链路控制器跑完整通、下行语音在扬声器出声,0 固件断言。iO 无音乐 app,A2DP 为 SDK 自带、非功能。在打过补丁的 Renode 上按实时运行。

# RayNeo io on Mac

在 Mac 上运行**原版未修改**的雷鸟 io 眼镜固件（BES1700，NuttX，多核），用 Renode 模拟硬件，并在 Mac 窗口里显示固件自己扫描输出的画面，接收表冠输入。

本仓库不包含固件。使用者需自备 StrixOS 升级包解出的文件夹（含 `OtaFileInfo.json`、`nuttx_ap.bin`、`nuttx_bth.bin` 等）。所有处理都在本机完成；不会上传固件，也不会刷写眼镜。

> 状态说明：下列「已验证」均有对应日志或截图证据；未列出的内容不代表已完成。

## 快速使用

```sh
# 一次性：Renode 放在 .local/renode/Renode.app；Python 资源分区工具（会从 PyPI 下载 littlefs-python）
sh scripts/setup-tools.sh

# 命令行运行 60 秒模拟时间，日志与画面写到 .local/runs/demo/
FONTS=/path/to/ttf sh scripts/emulate.sh /path/to/StrixOS-1.0.4.12 60 .local/runs/demo

# Mac 应用
sh scripts/build-app.sh                 # BUNDLE_RENODE=1 时把 Renode 一起打包进 .app
sh scripts/run-app.sh                   # 等同于 Finder 双击
```

应用首次启动会弹窗让你选择固件文件夹，可在「固件」菜单里重新选择或指定字体文件夹。键盘：空格单击、D 双击、L 长按、↑/↓ 或滚轮旋转表冠。生成的闪存/NAND 镜像和日志放在 `~/Library/Application Support/RayNeo io on Mac/runs/`。

## 原理概要

| 组件 | 文件 | 说明 |
|---|---|---|
| 安装后的 NOR 镜像 | `scripts/make-flash-image.py` | 见下节 |
| NAND 资源分区 | `scripts/make-nand-image.py` | littlefs，按 `BurnMode 3` 放入 `/mnt/nand_resource/`；字体可选 |
| 板级描述 | `platform/best1700.repl` | AP（M55C0）、M55C1、BTH（M33）、BTC（M4）四个核 |
| 外设模型 | `platform/peripherals/*.cs` | 由固件访问推断，未做实机校准 |
| 运行脚本 | `scripts/emulate.sh`、`scripts/make-resc.py` | 生成镜像、Renode 脚本，挂载固件日志钩子 |

### BTH 启动问题（已解决）

升级包中每个 `BurnMode 1` 镜像首字都是 `0xFFFFFFFF`，而运行中的固件要求已安装镜像首字为 BES 启动魔数 `0xBE57EC1C`：

- AP 自身：`norflash_calib_magic_word_valid` / `norflash_sample_delay_calib` 读取 `0x30190000`（AP 镜像起点）并与 `0xBE57EC1C` 比较。
- `bt_host_open` 调用 `subsys_check_boot_struct(0x28000000)`，`cp_subsys_open` 调用 `subsys_check_boot_struct(0x30C10000)`，均要求该魔数，然后跳到镜像 +0x10。
- 每个镜像末尾有构建信息尾 `<0xBE57341D><安装地址>`：AP `0x30190000`、APC1 `0x30C10000`、BTH `0x28000000`。AP 的 `hal_norflash_addr_to_id` 表把 `0x08000000/0x28000000` 定为第二颗 NOR（flash id 1），AP 打印的分区表（`apc1 first 24704`、`hifi first 28800` 块，每块 512 字节）与这些地址一致。
- 音频 DSP 镜像的尾部是内存装载地址 `0x1BC00000`；`dsp_open` 从 `0x30E10000` 拷贝 4 MiB 到该地址，不检查首字，所以按原样放入。
- `smf.json`、`pil_algo_vad_demo.dll` 是 `BurnMode 2`，地址直接写在 `OtaFileInfo.json`。

脚本只改写首字（升级完成后由眼镜上的安装程序写入，这一步在升级包中看不到，属于根据上述检查得出的推断），其余字节与升级包一致，并逐个核对大小和 MD5。

### 模拟器侧的修正（没有改固件指令）

- **ARMv8-M PPB 与 MPU**：架构规定特权访问 `0xE0000000-0xE00FFFFF` 不受 MPU 检查；Renode 1.17 的 PMSAv8 实现会检查，导致 BTH 在 MPU 打开（PRIVDEFENA=0）后读取 VTOR 即触发 MemManage。做法是给 BTH/M55C1 多开一个固件看不到的 MPU 区域（编号 16）覆盖 PPB，`BES1700_PPBExemptNVIC` 在 MPU_TYPE 中仍报告 16 个区域，固件自检和区域循环都不会碰到它。
- **核间邮箱**：AP↔BTH、M55C1↔BTH（`0x40000000` 与 `0x50000000` 两组寄存器，按 2 位一组的 lane 划分）以及 AP↔M55C1（`0x40000090/94`），寄存器语义和中断号来自双方 HAL 和 `rmt_ipc` 配置表。
- BTH 侧 CMU、I2C、DMA、IMU（Renode 自带 LSM6DSO 模型替代 LSM6DSO32）。
- GPU（VGLite 命令缓冲执行）、LCDC 双眼 G4 扫描输出、GPIO/PSC 中断、OTS 光学旋钮：取自 `.local/research/parallel/` 的并行研究草稿并接入正式配置。

## 已验证（2026-10-16，原版 1.0.4.12 固件，均有日志/截图）

- 四个核（AP、M55C1、BTH、BTC）全部启动；约 12 秒模拟时间进入原厂桌面（`BoardView::show`），整次运行无断言。
- **已配对开机**：`scripts/make-user-data.py` 在 NOR 用户数据区（0x30FF0000/0x30FEE000，偏移 0x1CEC）写入与真机配对后相同格式的绑定记录，原厂 Launcher 直接进主页；`BOND=0` 保留出厂的配对引导页。
- **中文/多语言字体**：18 个 nand_font 全部加载成功。其中 4 个原厂文件取自用户自己的雷鸟 AI App，其余为同一开源字族（Noto、Vazirmatn、思源黑体 KR），`pixel_monospaced_latin_sub` 用 VT323 替身。见 `scripts/prepare-fonts.sh`。
- **时间**：PMU 日历寄存器（0x17D–0x180，BCD）跟随 Mac 本地时间，主页时间日期正确。
- **电量**：左右镜腿两颗 MAX17335（I2C0 0x36/0x0B、0x76/0x4B）被识别，主页显示电量；USB 检测脚（GPIO2 bit20）默认未插线。
- **表冠**：单击进应用列表、再单击打开应用、长按/双击唤醒 RayNeo AI、旋转在应用列表里切换（录音→实时字幕→实时提示），全部由原固件处理（`tests/scenarios/crown.txt`、`rotate.txt`）。
- **硬件定时器**：SP804 双定时器（0x40083000/0x40002000）补上后，按键去抖等软件定时器正常；I2C 改用自建 DesignWare 模型，不再出现读超时。
- **蓝牙控制器**：BTC 原固件通过基带版本/软复位检查，响应主机 HCI 命令（Reset、读版本/地址、设置名称、事件掩码等），BLE 广播能开启。
- **Mac 应用**：窗口显示原固件画面，空格按住=按表冠、滚轮/方向键=旋转；退出时保存 NOR+NAND，下次启动恢复（设置、配对、文件保留）；「恢复出厂设置」清除。固件选择后复制到应用数据目录，避免访问「文稿」触发系统授权弹窗。

## 未完成 / 与真机仍有差异

- **手机连接**：BTC 基带没有射频和基带定时中断模型，无法与任何手机真正连接；依赖手机 App 的功能（录音、字幕、提示、导航、AI 对话等）会停在「请将眼镜连接至手机 App」。
- **音频**：HiFi4 音频 DSP、麦克风、扬声器未建模，没有声音输入输出。
- **其他传感器**：IMU 只有静态数据（头部手势不可用），磁力计总线地址为推测，光感 W1160、佩戴检测、Wi‑Fi 未建模。
- **速度**：约为实时的 1/8，开机到桌面约 2 分钟。主要开销在核间同步与 M55C1 的轮询，尚未优化。
- `pixel_monospaced_latin_sub` 字体不是原厂文件（未识别出原字体）。

## 研究工具

`.local/research/` 下为本机研究记录与草稿（不入库）。固件日志通过 Renode CPU 钩子从固件自己的 `hal_trace`/`syslog` 入口读取，带 `[AP]`、`[BTH]`、`[C1]` 前缀；钩子只读内存，不改变执行。

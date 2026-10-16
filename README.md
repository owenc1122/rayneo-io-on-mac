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

## 已验证（2026-10-13，原版 1.0.4.12 固件）

- AP 原固件完成 NuttX 启动、驱动初始化，显示开机标志。
- 安装后的 BTH 镜像通过 AP 的启动结构检查（日志：`subsys_check_boot_struct: boot_addr=0x28000000 magic=0xBE57EC1C`），BTH 核被释放并启动自己的 NuttX，完成 I2C、IMU、rpmsg 初始化，与 AP 双向 rpmsg 通信（AP 下发 IMU 参数，BTH 回 ACK：`[BTH] IMU params ACK sent successfully`）。
- AP 越过 BTH 打开阶段，继续启动服务、LVGL 和 Launcher，日志出现 `Launcher: First frame ready`、`BondView: Show`（未配对设备的绑定页）。
- NAND 资源分区：固件从模拟 NAND 挂载 littlefs，读到 `images.bin`、`lotties.bin` 和字体（`Rayneo create font CN_20 success`）。
- GPU 收到 LVGL 的真实命令缓冲并由模型执行。
- 证据日志：`.local/runs/t13/boot.log`（BTH 启动）、`.local/runs/t15/boot.log`（资源与字体）。

## 未完成 / 阻塞

- **bluetoothd 断言**：AP 的 bluetoothd 通过 rpmsg 调用 M55C1（`nuttx_apc1.bin`，`RPC_SERVER`）。M55C1 已作为第四个核接入并能被 AP 启动、完成 IPC 打开，但 AP↔M55C1 握手尚未稳定，约 38 秒处 `rpc_plat_cond_wait` 超时断言后系统复位。这是目前进入桌面的主要阻塞。
- 因上面的复位，Mac 窗口里尚未看到完整的 Launcher 画面（截至最后一次运行，扫描输出的帧为空白/开机标志）。
- 18 个出厂字体不在升级包里；可用 `FONTS=` 指定同名或同族字体（脚本对 `sh_sans_cn_reg_sub.ttf`、`roboto_condensed_reg_en_sub.ttf` 支持明确标注的替身），这些不是原厂文件。
- HiFi4 音频 DSP、Wi‑Fi、BTC 射频、电池计、光感等没有完整模型；相关驱动报错但不阻塞启动。
- 模拟速度约为实时的 1/4～1/5，进入 Launcher 需要数分钟真实时间。
- 输入链路（GPIO 按键、OTS 旋钮注入、Mac 键盘映射）已接好，但尚未在 Launcher 界面上完成端到端验证。
- 可移植 `.app`：已改为从包内 Resources 读取模型和脚本、通过对话框选择固件、日志写到 Application Support，不再依赖源码目录；需要系统 `python3`，资源分区还需一次性安装 littlefs-python。

## 研究工具

`.local/research/` 下为本机研究记录与草稿（不入库）。固件日志通过 Renode CPU 钩子从固件自己的 `hal_trace`/`syslog` 入口读取，带 `[AP]`、`[BTH]`、`[C1]` 前缀；钩子只读内存，不改变执行。

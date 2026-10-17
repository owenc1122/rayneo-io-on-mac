# RayNeo io on Mac

在 Mac 上运行**原版未修改**的雷鸟 io 眼镜固件（BES1700，NuttX，多核），用 Renode 模拟硬件，并在 Mac 窗口里显示固件自己扫描输出的画面，接收表冠输入。

本仓库不包含固件。使用者需自备 StrixOS 升级包解出的文件夹（含 `OtaFileInfo.json`、`nuttx_ap.bin`、`nuttx_bth.bin` 等）。所有处理都在本机完成；不会上传固件，也不会刷写眼镜。

> 状态说明：下列「已验证」均有对应日志或截图证据；未列出的内容不代表已完成。

## 快速使用

```sh
# 一次性：Renode（sh scripts/get-renode.sh，需 1.17.0+20261016 或更新；或 sh scripts/build-renode.sh 从源码构建同一版本加 renode-patches/ 的提速补丁，构建结果优先使用）；Python 工具（从 PyPI 下载 littlefs-python、fonttools）
sh scripts/setup-tools.sh

# 命令行运行 60 秒模拟时间，日志与画面写到 .local/runs/demo/
FONTS=/path/to/ttf sh scripts/emulate.sh /path/to/StrixOS-1.0.4.12 60 .local/runs/demo

# Mac 应用
sh scripts/build-app.sh                 # BUNDLE_RENODE=1 时把 Renode 一起打包进 .app
sh scripts/run-app.sh                   # 等同于 Finder 双击
```

虚拟手机（BLE）：

```sh
python3 scripts/ble-peer.py --port 23600 --log peer.log &
sh scripts/emulate.sh /path/to/StrixOS-1.0.4.12 40 .local/runs/ble "$PWD/Tests/scenarios/ble-peer.resc"
```
声音（见下文「音频」）：命令行运行时，原固件播放的声音写到输出目录的 `speaker.raw`（48 kHz 立体声 s16le），`MIC=<wav>` 指定录音输入；`python3 scripts/check-audio.py <输出目录> [mic.wav]` 把两者转成 WAV 并给出电平和相关性。Mac 应用直接用 Mac 的麦克风和扬声器（首次会请求麦克风权限）。

应用首次启动会弹窗让你选择固件文件夹，可在「固件」菜单里重新选择或指定字体文件夹。键盘：空格单击、D 双击、L 长按、↑/↓ 或滚轮旋转表冠。生成的闪存/NAND 镜像和日志放在 `~/Library/Application Support/RayNeo io on Mac/runs/`。

## 原理概要

| 组件 | 文件 | 说明 |
|---|---|---|
| 安装后的 NOR 镜像 | `scripts/make-flash-image.py` | 见下节 |
| NAND 资源分区 | `scripts/make-nand-image.py` | littlefs，按 `BurnMode 3` 放入 `/mnt/nand_resource/`；字体可选 |
| 板级描述 | `platform/best1700.repl` | AP（M55C0）、M55C1、BTH（M33）、BTC（M4）四个核 |
| 外设模型 | `platform/peripherals/*.cs` | 由固件访问推断，未做实机校准 |
| 运行脚本 | `scripts/emulate.sh`、`scripts/make-resc.py` | 生成镜像、Renode 脚本，挂载固件日志钩子 |
| 音频 DSP 替身 | `platform/peripherals/BES1700_HiFi4.cs` | 代替 HiFi4 DSP 完成核间协议和音频收发，见下节 |

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

### 音频（HiFi4 DSP）

升级包里的 `nuttx_audio.bin` 是 Cadence HiFi4 DSP 的程序（FreeRTOS/XCC，大量 FLIX 指令包）。smf.json 显示录音（5 路麦克风 16 kHz + Elevoc 降噪/波束 "up" 算法 + Opus 编码）、唤醒词（"wakeup" KWS 算法）、解码混音和扬声器 DMA 都在这颗 DSP（smf cpuid 4）上，AP 只负责共享内存队列两端。Renode 只有 Xtensa sample_controller 核：把镜像装到 `0x1BC00000`、PC 设为复位向量 `0x1BC00460`，第 14 条指令（`0x1BC004E3`）就报 "unrecognized opcode"，而且 KWS/up 算法 DLL 同样是 Xtensa 代码。所以不运行 DSP，改为在模拟器里实现 **DSP 对 AP 的接口契约**（偏移均来自 AP 镜像，研究记录在 `.local/research/audio/`）：

- **邮箱**：与 AP↔M55C1 共用 sys CMU `+0x90/+0x94`，DSP 链路占 bit0–10（AP 中断 76/77 收、79/80 发完成）；rmt_ipc 通道表通过 `0x20afffa0/0x20afffa4` 交换。
- **rptun/rpmsg**：远端填写 audio 资源表（`0x23c00260`）的 vring0，等 AP 写 DRIVER_OK，然后用标准 virtio 环收发；DSP 端点 `smf_m55c0_hifi4`（DSP 镜像里的同名端点）通过 NS 公告，AP 绑定后发来 ICS 块地址（`0x23c1d000`），替身置 DSP 就绪位。
- **smf**：应答流的 Add/Remove/Set/Get，按名字分配共享内存 FIFO（池消息 0x20/0x22，魔数 `0x55AA5A5A`），在 FIFO 里写/读帧和媒体描述。
- **声音数据**：录音流按 AP 要求的格式出帧：PCM，或用 macOS AudioToolbox 编码的 Opus（60 ms 一包）；播放流按媒体类型（mp3/aac/opus/pcm）用 AudioToolbox 解码成 DSP 混音格式 48 kHz 立体声。
- **AP 控制台输入**：UART0 实际中断号是 55（HAL 表 `0x1829ab14` 第 4 字节），接收走 DMA + 接收超时中断；补上后场景脚本可以用 `uart WriteLine` 在 `ap>` 下敲命令。

#### 语音唤醒「小雷小雷」（两级，与真机相同的链路）

- **开关**：语音唤醒是手机 App 里的设置（偏好 key 0x15，出厂为关）。`VOICE_WAKE=1` 用 `scripts/set-preference.py` 把它写进 NOR 用户数据区，等同于在 App 里打开；Mac 应用的「声音」菜单里有同名开关（默认开）。`WAKE_WORD=2` 对应 App 里的英文唤醒词。
- **第一级（原厂代码真实运行）**：AP 打开 BTH 上的 vad 流（0x18），BTH 的原厂 VAD/唤醒库 `pil_algo_vad_demo.dll` 通过 codec ADC2 → BTH DMA1 拿到 Mac 麦克风的声音。为此补了 codec（0x50300000，寄存器可读回，否则 AP 驱动在 `hal_codec_adc_chan_config` 断言）和芯片 ID（AON `0x40080000` = 0x6a4，否则 BTH 动态加载器拒绝加载该库）。原厂库判定唤醒词后发 `bth vad ready`。
- **第二级（DSP 替身）**：AP 随后在 DSP 上打开 wakeup 流（0x1b），替身用 Notify（msgid 0xff，事件 0x11）回报结果：4 = 小雷小雷、2/3 = OK/Hey RayNeo、6 = 未确认、0 = 历史音频已送出。判定来自两个本机识别器：命令行运行用内置的模板匹配（MFCC + 动态时间规整，模板由 `scripts/make-kws-templates.sh` 用 macOS 自带中英文语音生成，可加入自己的录音）；Mac 应用另外用系统的设备端语音识别（不上传）。wakeup 流里的音频按 AP 的要求写成 8 字节头 + 240 字节恒定码率 Opus。
- **固件自身的行为（照原样复现）**：开机时 KWS 打开请求比 mediad 就绪早约 50 ms 而失败（mediad 要等 1 秒 M55C1 的 smf 就绪，而 M55C1 镜像里根本没有 smf），之后要等一次助手交互（如双击）才重新打开；没有手机连接时固件处于离线状态，第一级命中会尝试拉起 iPhone App（与双击相同的「正在唤醒 RayNeo AI」），第二级结果按固件逻辑被忽略。

#### 麦克风阵列与降噪

DSP 的录音管线要 5 路（chmap 0x3d000：左、右、右 2、前、骨传导 VPU），BTH 的 codec2 要 2 或 3 路。所有通道送同一路 Mac 麦克风信号（相当于安静环境里单人说话），DSP 的 Elevoc 降噪/波束（"up" 库，Xtensa 代码）按直通处理：输出等于输入。

#### 1/8 速度下的实时声音

- 麦克风：所有消费者共用一条按模拟时间编号的 16 kHz 时间线。Mac 应用实时写入 `mic.raw`，积压超过 0.5 秒时替身丢弃积压里的静音，说话内容完整送达且延迟不再累积。
- 扬声器：替身按 DSP 真实播放速度（模拟时间）从 AP 取帧，所以 AP 受到和真机一样的反压；`speaker.events` 记录每段播放的起止，Mac 应用等一段播放完整（或攒满 10 秒）后再以正常速度播出，不会断续。

## 已验证（2026-10-16，原版 1.0.4.12 固件，均有日志/截图）

- 四个核（AP、M55C1、BTH、BTC）全部启动；约 12 秒模拟时间进入原厂桌面（`BoardView::show`），整次运行无断言。
- **已配对开机**：`scripts/make-user-data.py` 在 NOR 用户数据区（0x30FF0000/0x30FEE000，偏移 0x1CEC）写入与真机配对后相同格式的绑定记录，原厂 Launcher 直接进主页；`BOND=0` 保留出厂的配对引导页。
- **中文/多语言字体**：18 个 nand_font 全部加载成功。其中 4 个原厂文件取自用户自己的雷鸟 AI App，其余为同一开源字族（Noto、Vazirmatn、思源黑体 KR），`pixel_monospaced_latin_sub` 用 VT323 替身。见 `scripts/prepare-fonts.sh`。
- **时间**：PMU 日历寄存器（0x17D–0x180，BCD）跟随 Mac 本地时间，主页时间日期正确。
- **电量**：左右镜腿两颗 MAX17335（I2C0 0x36/0x0B、0x76/0x4B）被识别，主页显示电量；USB 检测脚（GPIO2 bit20）默认未插线。
- **表冠**：单击进应用列表、再单击打开应用、长按/双击唤醒 RayNeo AI、旋转在应用列表里切换（录音→实时字幕→实时提示），全部由原固件处理（`tests/scenarios/crown.txt`、`rotate.txt`）。
- **硬件定时器**：SP804 双定时器（0x40083000/0x40002000）补上后，按键去抖等软件定时器正常；I2C 改用自建 DesignWare 模型，不再出现读超时。
- **蓝牙控制器**：BTC 原固件通过基带版本/软复位检查，响应主机 HCI 命令（Reset、读版本/地址、设置名称、事件掩码等），BLE 广播能开启。
- **蓝牙基带**（`BES1700_BTController`）：两套 RW-IP 公共块（0x6d040000→BTC IRQ 1、0x6d060000→IRQ 39）的定时目标 1–3、软件中断、交换表活动调度（ACTSCHCNTL 0x110、ET 状态、活动 FIFO 结束/跳过）。BLE 广播按间隔真实运行（开启状态 0，之前为 2）；主机按绑定记录回连 iPhone 时控制器真实返回寻呼超时（status 4），iOS SPP 重试 3 次，C1 不再出现 `bes_hci_send_data osEventTimeout` 断言（60 秒运行，`Tests/scenarios/bt-reconnect.txt`）。
- **虚拟手机（BLE 链路层）**：`scripts/ble-peer.py` 作为中心设备，通过基带模型的空口桥（`btcRadio PeerPort`，交换内存 RX/TX 描述符 + 活动 FIFO 收发帧中断）连接原固件：CONNECT_IND 被接受，主机报告 LE ACL/GATT 已连接，LL 版本/特性/长度过程完成，ATT MTU 247，发现 GATT 数据库（GAP、GATT、RayNeo 服务 0xB81D：通知特征 `7db3e235…`、写特征 `ea8b70d5…`/`ea8b60c5…`），订阅后眼镜通过 0x8002 主动发出 rnlink 帧（`aa55…`）。
- **录音（麦克风 → 原固件）**：主页双击表冠（画面「正在唤醒 RayNeo AI」），原固件的 `AudioAdapter::startMfiWakeupPreroll` 打开语音预录（smf 流 arec2，要求 Opus 32 kbps / 60 ms）；替身把 `MIC` 指定的 WAV 编码成 Opus 送入共享内存队列，AP 日志出现 `rayneo-record-sock:record-start-success` 并持续读帧、无溢出。`scripts/check-audio.py` 把 AP 收到的 91 个 Opus 包解码回 WAV，与输入的相关系数 0.97（`tests/scenarios/record.txt`）。
- **播放（原固件 → 扬声器）**：无手机时原固件的本地提示音是空实现（`rayneo_audio_local_music_play` 只打日志），播放来自手机 TTS/音乐/通话。离线可用的原厂路径是 AP 控制台的 `mediatool` 工厂扬声器测试：`fspeakerstart 2` 播放固件内嵌的 MP3（`buff://0x182a5a6a_11472.mp3`），经 AP 解复用 → aplay1 共享内存队列 → 替身解码，`speaker.raw` 得到 2.5 秒满幅 1 kHz 正弦（`tests/scenarios/speaker.txt`）。
- **语音唤醒「小雷小雷」**（`VOICE_WAKE=1`）：BTH 原厂 VAD/唤醒库在模拟 codec 上真实运行（`vad demo start`），听到 Mac 输入的「小雷小雷，今天天气怎么样」后发 `bth vad ready`，替身第二级确认（hifi 事件 4），固件走离线分支（`OfflineState ... fast wakeup, ios launch app`）（`Tests/scenarios/wake.txt`）；「小李小李」「今天天气怎么样」「晓蕾在哪里」「小米小米」不触发（`wake-negative.txt`）；带背景噪声同样通过。实时输入（`scripts/live-mic-feed.py` 代替 Mac 麦克风按真实时间写入）：运行 9 分钟后说出的唤醒词立即送达模拟麦克风（已丢弃 464 秒静音），约 1 秒模拟时间内两级都触发。
- **Mac 应用里的声音**：麦克风授权后 `mic.raw` 以 16 kHz 实时增长并送入原固件（环境声 rms≈1000，延迟上限 4 秒）；工厂扬声器测试的 1 kHz 音在 Mac 扬声器上连续播完（`speaker.played` 两段缓冲按时长首尾相接）。
- **Mac 应用**：窗口显示原固件画面，空格按住=按表冠、滚轮/方向键=旋转；退出时保存 NOR+NAND，下次启动恢复（设置、配对、文件保留）；「恢复出厂设置」清除。固件选择后复制到应用数据目录，避免访问「文稿」触发系统授权弹窗。

## 未完成 / 与真机仍有差异

- **手机连接**：BLE 链路层已能与虚拟手机连接，但虚拟手机还不会说 rnlink 协议（帧格式 `aa55` 已见，消息未解析），所以依赖手机 App 的功能仍停在「请将眼镜连接至手机 App」。尚未建模：BR/EDR（寻呼/寻呼扫描后的 ACL、LMP，因此 SPP/RFCOMM、iAP2、A2DP、HFP 都不可用）、链路加密与 SMP 配对（AES 引擎 0xb0–0xc4、CRYPT 中断）、第二套基带 IP（0x6d060000）的空口桥、每个连接事件只收发一个 PDU。iOS 上 rnlink 依赖 iAP2（BR/EDR + MFi 认证芯片签名），模拟器无法产生该签名，真 iPhone 的 iAP2 功能不可能在纯模拟下工作。
- **音频**：HiFi4 DSP 不执行，只实现其接口（见「音频」一节），DSP 上的唤醒词第二级与降噪/波束由替身完成（本机识别 / 直通），不是原厂 Xtensa 算法。A2DP 音乐与 HFP 通话的音频要等经典蓝牙（BR/EDR）建模后接入。AP 繁忙时模拟只是勉强跟上实时（机器负载高时会略慢），Mac 应用里的声音按整段延后播放。
- **其他传感器**：光感 W1160（I2C1 0x48，固件读到 250 lux）、磁力计 MMC5603NJ（BTH I2C1 0x30，ID 0x10）已被原固件识别。IMU 换成自建 LSM6DSO32 模型（FIFO、INT1 低有效），中断经 PSC 的 BTH 组寄存器（使能 0x12c/0x1b4/0x1d8、状态 0x138/0x1b8/0x1dc，BTH NVIC 2）送达 BTH，BTH 按水位持续读 FIFO，颈部姿态监测拿到数据。`headMotion`（Pose/Nod/Shake/Turn，按出厂默认安装角 101°/−65°/−65° 反变换）可驱动它。原厂「抬头亮屏」默认关闭（手机 App 的 headup_switch），点头/摇头只在来电等场景由 AP 开启检测，这两项要等手机端协议才能完整验证。iO 没有佩戴传感器（`controlCapSensorAsync` 为空实现），状态机在按表冠后由 LIGHT_SLEEP 进入 RUNNING。BTH I2C1 的 DMA 模式未建模（固件两次超时后改用 FIFO）。Wi‑Fi 未建模。
- **速度**：开机 20 秒模拟时间约 20 秒（Renode 启动另需约 6 秒）；桌面待机比实时快约 2–3 倍，Mac 应用（及命令行 `REALTIME=1`）把虚拟时间限制在不超过实时；用源码构建的 Renode 时，表冠场景每一段都不慢于实时（最重的双击唤醒动画段 2 秒模拟时间约 2.0 秒、长按段 2.5 秒约 2.5 秒；不限速时分别约 1.6、1.7 秒）；运行时比原来多占约 0.6 个 CPU 核（线程交接时先短暂自旋再休眠）。做法：AP、M55C1 真正进入 WFI 睡眠；DMA 按块搬运、NAND FIFO 批量读；固件的忙等延时（`hal_sys_timer_delay_us/_ns`、AON 计数器轮询）改为让核跳过相应的虚拟时间（`SkipTime`，不清翻译缓存）；GPU 路径填充用活动边表、唤醒词识别的 FFT 系数预先算好（结果逐位相同）；`scripts/build-renode.sh` 给 Renode 打 `renode-patches/` 里只影响速度的补丁：tlib（macOS 上不保存信号掩码的 setjmp、Cortex-M 写数据页时跳过 MPU 查表、普通写在无独占预约时不拿全局锁、arm64 后端内联 TLB 快速路径与更短的常数/立即数编码、断点按页失效、写代码页时用代码位图、过期块首回调直接返回）和 C# 基础设施（时间片交接先自适应自旋再阻塞、移走 PC 的钩子不再拆装断点）。四核串行执行（`SERIAL=0` 并行，偶发自旋锁活锁）。调试开关：`HOOKS=0` 去掉 Python 日志钩子，`IDLE_SPIN=1` 恢复 C1 空转，`DELAY_SPIN=1` 恢复忙等延时，`AON_POLL=0` 关掉 AON 计数器轮询暂停，`DMA_BLOCK=0` 恢复 DMA 逐字搬运，`QUANTUM=<秒>` 改核间同步量子（默认 0.0001；调大虽更快但会改变双击后的界面走向，不建议），`ADVANCE=1` 让 Renode 不按主机时钟限速（只用于测模拟器本身速度；默认虚拟时间不超前主机时间）。
- `pixel_monospaced_latin_sub` 字体不是原厂文件（未识别出原字体）。

## 研究工具

`.local/research/` 下为本机研究记录与草稿（不入库）。固件日志通过 Renode CPU 钩子从固件自己的 `hal_trace`/`syslog` 入口读取，带 `[AP]`、`[BTH]`、`[C1]` 前缀；钩子只读内存，不改变执行。

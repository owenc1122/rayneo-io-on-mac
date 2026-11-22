# 虚拟手机 peer.log 行格式

`scripts/ble-peer.py --log peer.log`（`Tests/spare/run.sh` 写到 `<输出目录>/peer.log`）。每行以本机墙钟 `HH:MM:SS ` 开头。
回放夹具（安卓 `EmuReplayTest` 的 `fl-link-a/peer-*.log`、iOS `GlassesTraceReplayTests` 的 `Fixtures/GlassTrace/peer-*.log`）
就是按行过滤出来的 peer.log，所以**已有行的格式不许改**，只能加新的行类型。

## 夹具依赖的已有行（不变）

| 行 | 含义 | 谁在读 |
|---|---|---|
| `rnlink <- <业务名或 0xNN> ctrl=<十进制> flags=<十六进制> <负载十六进制>[ CRC-BAD]` | 拼好的一帧眼镜 → 手机 rnlink 帧（负载 = 业务号之后、CRC 之前） | 安卓夹具：取这类行，去掉 `CRC-BAD` 和 `RNLINK` |
| `rnlink <业务名> type=<n> msg=<JSON>` | LAUNCHER_CMD / RECORD_CMD 等 PbMsg 的解码 | iOS 夹具：取 `type=6 msg=` 里 `spare_trace_v1` 的行；`Tests/spare/trace.py` |
| `rnlink resync, dropping <十六进制>` | 一个续片最终没有任何帧认领，被丢弃 | 人看 |
| `raw chunk len=<n> <十六进制>` | 只在 `--raw`（`run.sh` 设 `PEER_RAW=1`）时：收到的每个 GATT 通知分片原样 | `Tests/spare/test_reasm.py` 回放 |

## 新增行类型（2026-11-22，fix/emu-peer-reassembly）

### SGE1 事件

```
HH:MM:SS SGE1 event=<事件号> caps=<b12>.<b16><b17><b18><b19> len=<字节数> raw=<整个事件十六进制>
```

眼镜发来的每个 SGE1 事件一行（任何 LAUNCHER_CMD JSON 的 `payload.data` 以 `SGE1` 开头，目前是 `spare_ai_v1`），
写在该帧原有的 `rnlink LAUNCHER_CMD type=… msg=…` 行之后。

- `event`：byte 5，十进制。
- `caps`：能力字节，十六进制，按 App 的解码（ios-next `Assistant.swift` `Assistant.Event`）：
  `b12` = byte 12（能力一；事件 4–6 上这里是回显的 seq）、`.` 之后依次 byte 16（能力二）、17（能力三）、
  18 / 19（事件 16：扩展能力 / 扩展能力 2，如长正文能力位）。超出事件长度的字节写 `--`。
- `len`：事件字节数（正常 32）。
- `raw`：整个事件，方便看 tick（byte 8–11）、事件 12 的 op / 参数、事件 16 的固件版本（byte 20–24）等。

例：`SGE1 event=16 caps=3f.ffbf0e00 len=32 raw=5347453101100000…` —— 事件 16，byte 19 = 0x00、byte 18 = 0x0e。

找事件 16 的能力位：`grep 'SGE1 event=16 ' peer.log`。

### 拼不完整的帧

```
HH:MM:SS rnlink incomplete frame dropped ctrl=<十进制> have=<已有字节> total=<应有字节>
```

一个多片帧的头片到了，但续片始终凑不齐（上游真的丢了分片）：头片之后过了 `2 × 片数 + 256` 个分片仍拼不上，
或者仿真器断开 / 虚拟手机收到 SIGTERM 时还没拼上。

## 拼帧规则（scripts/rnlink_reasm.py）

仿真链路上眼镜的通知分片会乱序：尾片先于头片、中间片先于头片、相邻两片对调，几帧的分片交错。拼帧器把续片放进池子，
按「除尾片外每片都是整片（MTU−3 = 244 字节）、尾片恰好补足长度」挑候选，用 CRC16 加 protobuf 形状判定。
十几 KB 的大帧（原厂 analytics_log_bulk、常开录音）里换位太多，CRC16 区分不了，仍按到达顺序拼出并标 `CRC-BAD`（与以前相同）。
自测：`python3 Tests/spare/test_reasm.py [带 raw chunk 的 peer.log ...]`。

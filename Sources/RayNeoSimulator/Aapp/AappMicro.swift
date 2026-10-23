import CoreGraphics
import CoreText
import Foundation

/// micro ("流畅") mode: the Host keeps the app's UI tree on the simulator and sends edits as a command stream
/// (`microCommands`). Ops: 1 create(u32 id, str type), 2 insert(id, parent, pos), 3 destroy(id), 4 setProperty(id,
/// str key, value), 5 setEvent(id, str key), 6 setCustomContent(id, u32 version, f64 w, f64 h, u8 mode, ADRF bytes),
/// 7 control(id, str JSON). Values: u8 kind + 0 null, 1 u8 bool, 2 f64, 3 str, 4 JSON str.
enum MicroValue: Equatable {
    case null, bool(Bool), number(Double), string(String), json(String)

    var number: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .json(let j): return j
        case .null: return nil
        }
    }
    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return s == "true" ? true : s == "false" ? false : nil
        default: return nil
        }
    }
}

enum MicroCommand {
    case create(id: UInt32, type: String)
    case insert(id: UInt32, parent: UInt32, pos: UInt32)
    case destroy(id: UInt32)
    case setProperty(id: UInt32, key: String, value: MicroValue)
    case setEvent(id: UInt32, key: String)
    case setCustomContent(id: UInt32, version: UInt32, width: Double, height: Double, mode: UInt8, displayList: Data)
    case control(id: UInt32, json: String)

    static func parse(_ data: Data) throws -> [MicroCommand] {
        var r = AappReader(data)
        var out: [MicroCommand] = []
        while !r.isAtEnd {
            guard out.count < 100_000 else { throw AappReaderError(description: "Too many micro commands") }
            let op = try r.u8()
            switch op {
            case 1: out.append(.create(id: try r.u32(), type: try r.string(max: 256)))
            case 2: out.append(.insert(id: try r.u32(), parent: try r.u32(), pos: try r.u32()))
            case 3: out.append(.destroy(id: try r.u32()))
            case 4:
                let id = try r.u32(), key = try r.string(max: 256)
                let kind = try r.u8()
                let value: MicroValue
                switch kind {
                case 0: value = .null
                case 1: value = .bool(try r.u8() != 0)
                case 2: value = .number(try r.f64())
                case 3: value = .string(try r.string())
                case 4: value = .json(try r.string())
                default: throw AappReaderError(description: "Unknown micro value kind \(kind)")
                }
                out.append(.setProperty(id: id, key: key, value: value))
            case 5: out.append(.setEvent(id: try r.u32(), key: try r.string(max: 256)))
            case 6:
                let id = try r.u32(), version = try r.u32(), w = try r.f64(), h = try r.f64(), mode = try r.u8()
                guard mode <= 2 else { throw AappReaderError(description: "Unknown custom content mode \(mode)") }
                out.append(.setCustomContent(id: id, version: version, width: w, height: h, mode: mode, displayList: try r.block(max: ADRFDecoder.maxFrameBytes)))
            case 7: out.append(.control(id: try r.u32(), json: try r.string()))
            default: throw AappReaderError(description: "Unknown micro opcode \(op)")
            }
        }
        return out
    }
}

final class MicroNode {
    let id: UInt32
    let type: String
    var props: [String: MicroValue] = [:]
    var children: [UInt32] = []
    var parent: UInt32?
    var events: Set<String> = []
    var custom: (frame: ADRFFrame, width: Double, height: Double, mode: UInt8)?
    /// Absolute layout box from the last layout pass.
    var frame: CGRect = .zero

    init(id: UInt32, type: String) { self.id = id; self.type = type }

    func num(_ key: String) -> Double? { props[key]?.number }
    func str(_ key: String) -> String? { props[key]?.string }
    func flag(_ key: String) -> Bool? { props[key]?.bool }
}

/// The retained tree plus a small Compose-like layout (Column/Row/Stack/Text/Image/Button/Space/Custom and
/// list/tab containers drawn as Column/Row) and focus handling for the crown/arrow keys.
final class MicroTree {
    private(set) var nodes: [UInt32: MicroNode] = [:]
    private(set) var root: UInt32?
    private(set) var focused: UInt32?
    var warn: (String) -> Void = { _ in }
    private(set) var wheels: [UInt32: WheelState] = [:]
    /// Component events (`uiEvents` type 8) waiting to be sent: node, key, JSON object.
    var pendingComponentEvents: [(UInt32, String, [String: Any])] = []

    func wheel(_ id: UInt32) -> WheelState? {
        guard let node = nodes[id], node.type == "WheelPicker" else { return nil }
        if let w = wheels[id] { return w }
        let w = WheelState(); w.configure(node); wheels[id] = w
        return w
    }
    static let maxNodes = 20_000

    /// The real Host never sets `active` on UIRoot (only test clients did), and the official simulator still draws
    /// the tree, so the root shows unless `active` is explicitly false.
    var isActive: Bool { root.flatMap { nodes[$0] }.map { $0.flag("active") != false } ?? false }

    func reset() { nodes.removeAll(); root = nil; focused = nil; wheels.removeAll(); pendingComponentEvents.removeAll() }

    func apply(_ commands: [MicroCommand]) {
        for command in commands {
            switch command {
            case .create(let id, let type):
                if nodes[id] != nil { warn("micro：节点 \(id) 重复创建，已替换"); destroy(id) }
                guard nodes.count < Self.maxNodes else { warn("micro：节点超过 \(Self.maxNodes) 个，忽略创建"); continue }
                if type == "UIRoot" {
                    if let root, nodes[root] != nil { warn("micro：只能有一个 UIRoot，忽略节点 \(id)"); continue }
                    root = id
                }
                nodes[id] = MicroNode(id: id, type: type)
            case .insert(let id, let parentId, let pos):
                guard let node = nodes[id], let parent = nodes[parentId] else { warn("micro：insert 节点不存在 \(id)→\(parentId)"); continue }
                guard id != root else { warn("micro：UIRoot 不能被插入"); continue }
                guard !isAncestor(id, of: parentId) else { warn("micro：insert 会形成环 \(id)→\(parentId)"); continue }
                if let old = node.parent { nodes[old]?.children.removeAll { $0 == id } }
                parent.children.insert(id, at: min(Int(pos), parent.children.count))
                node.parent = parentId
            case .destroy(let id):
                destroy(id)
            case .setProperty(let id, let key, let value):
                guard let node = nodes[id] else { warn("micro：setProperty 节点不存在 \(id)"); continue }
                if value == .null { node.props[key] = nil } else { node.props[key] = value }
                if key == "wheelConfig", node.type == "WheelPicker" {
                    let w = wheel(id)!; w.configure(node)
                    pendingComponentEvents.append((id, "wheel", w.event(phase: "state", source: "program")))
                }
                if key == "animationCommand" { warn("micro：动画暂不支持（节点 \(id)），直接显示终态") }
            case .setEvent(let id, let key):
                guard let node = nodes[id] else { warn("micro：setEvent 节点不存在 \(id)"); continue }
                if key != "click" { warn("micro：事件「\(key)」暂不支持，只支持 click") }
                node.events.insert(key)
            case .setCustomContent(let id, _, let w, let h, let mode, let list):
                guard let node = nodes[id] else { warn("micro：setCustomContent 节点不存在 \(id)"); continue }
                do { node.custom = (try ADRFDecoder.decode(list), w, h, mode) }
                catch { warn("micro：自绘内容解码失败（节点 \(id)）：\(error)") }
            case .control(let id, let json):
                let op = (json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
                if let w = wheel(id), let steps = (op?["steps"] as? NSNumber)?.intValue {
                    let source = op?["source"] as? String == "agent" ? "agent" : "controller"
                    if let delta = w.move(steps) {
                        pendingComponentEvents.append((id, "wheel", w.event(phase: "change", source: source, delta: delta)))
                        pendingComponentEvents.append((id, "wheel", w.event(phase: "commit", source: source)))
                    }
                } else {
                    warn("micro：control 操作暂未实现（节点 \(id)）：\(json.prefix(120))")
                }
            }
        }
        if let focused, nodes[focused] == nil { self.focused = nil }
        wheels = wheels.filter { nodes[$0.key] != nil }
    }

    /// Key on a focused WheelPicker: Enter toggles adjusting, ↑/↓ move while adjusting, Esc ends adjusting.
    /// Returns true when the wheel consumed the key.
    func wheelKey(_ key: AappKey) -> Bool {
        guard let focused, let w = wheel(focused), !w.values.isEmpty else { return false }
        switch key {
        case .enter:
            w.editing.toggle()
            pendingComponentEvents.append((focused, "wheel", w.event(phase: w.editing ? "state" : "commit", source: "key")))
            return true
        case .up, .down:
            guard w.editing else { return false }
            if let delta = w.move(key == .up ? -1 : 1) { pendingComponentEvents.append((focused, "wheel", w.event(phase: "change", source: "key", delta: delta))) }
            return true
        case .escape:
            guard w.editing else { return false }
            w.editing = false
            pendingComponentEvents.append((focused, "wheel", w.event(phase: "commit", source: "key")))
            return true
        default: return false
        }
    }

    private func isAncestor(_ a: UInt32, of b: UInt32) -> Bool {
        var cursor: UInt32? = b, steps = 0
        while let c = cursor, steps < Self.maxNodes { if c == a { return true }; cursor = nodes[c]?.parent; steps += 1 }
        return false
    }

    private func destroy(_ id: UInt32) {
        guard let node = nodes[id] else { return }
        if let p = node.parent { nodes[p]?.children.removeAll { $0 == id } }
        var stack = [id], visited = 0
        while let n = stack.popLast(), visited < Self.maxNodes {
            visited += 1
            if let child = nodes.removeValue(forKey: n) { stack.append(contentsOf: child.children) }
        }
        if root == id { root = nil }
    }

    // MARK: layout

    private static let containerTypes: Set<String> = ["UIRoot", "Stack", "Button", "Tab", "TabPage", "Navigation", "NavigationRoute", "LazyItem", "LazyGridItem"]
    private static let columnTypes: Set<String> = ["Column", "LazyColumn", "LazyGrid"]
    private static let rowTypes: Set<String> = ["Row", "LazyRow"]
    private static let knownLeaf: Set<String> = ["Text", "Image", "Space", "Custom", "Progress", "Slider", "TextField", "MarkdownView", "SourceCode", "WheelPicker"]
    static let focusableTypes: Set<String> = ["Button", "TextField", "Slider", "WheelPicker"]

    /// Children that are shown: hidden nodes are skipped, and for routes/tab pages only the active one.
    func visibleChildren(_ node: MicroNode) -> [MicroNode] {
        let kids = node.children.compactMap { nodes[$0] }.filter { $0.flag("visible") != false && $0.flag("hidden") != true }
        if ["Navigation", "Tab"].contains(node.type) || kids.contains(where: { ["NavigationRoute", "TabPage"].contains($0.type) }) {
            let paged = kids.filter { ["NavigationRoute", "TabPage"].contains($0.type) }
            if !paged.isEmpty {
                let active = paged.filter { $0.flag("active") == true }
                let shown = active.isEmpty ? [paged.last!] : [active.last!]
                return kids.filter { !["NavigationRoute", "TabPage"].contains($0.type) } + shown
            }
        }
        return kids
    }

    private func padding(_ n: MicroNode) -> (l: CGFloat, t: CGFloat, r: CGFloat, b: CGFloat) {
        let all = CGFloat(n.num("padding") ?? 0)
        return (CGFloat(n.num("paddingLeft") ?? Double(all)), CGFloat(n.num("paddingTop") ?? Double(all)),
                CGFloat(n.num("paddingRight") ?? Double(all)), CGFloat(n.num("paddingBottom") ?? Double(all)))
    }

    /// Explicit dimension: a positive number, or "fill"/"match"/"100%"/negative = the available space.
    private func dimension(_ n: MicroNode, _ key: String, available: CGFloat) -> CGFloat? {
        guard let value = n.props[key] else { return nil }
        if case .string(let s) = value {
            let lower = s.lowercased()
            if ["fill", "match", "match_parent", "matchparent", "max", "100%", "full"].contains(lower) { return available }
            if lower.hasSuffix("%"), let p = Double(lower.dropLast()) { return available * CGFloat(p / 100) }
            if let d = Double(lower) { return CGFloat(d) }
            return nil
        }
        guard let d = value.number else { return nil }
        if d < 0 { return available }
        return CGFloat(d)
    }

    private func spacing(_ n: MicroNode) -> CGFloat { CGFloat(n.num("space") ?? n.num("spacing") ?? n.num("gap") ?? 0) }

    func textFont(_ n: MicroNode) -> CTFont {
        let weight: Double?
        switch n.props["fontWeight"] {
        case .number(let w): weight = w
        case .string(let s): weight = ["bold", "semibold", "w600", "w700", "w800", "w900", "heavy", "black"].contains(s.lowercased()) ? 700 : Double(s)
        default: weight = nil
        }
        return AappCanvas.font(n.str("font"), size: CGFloat(n.num("fontSize") ?? defaultFontSize(n)), weight: weight)
    }
    private func defaultFontSize(_ n: MicroNode) -> Double { n.type == "TextField" ? 18 : n.type == "SourceCode" ? 14 : n.type == "MarkdownView" ? 16 : 14 }

    /// Wrapped lines of a text node within `width` (nil = no wrapping), honouring maxLines.
    func textLines(_ n: MicroNode, width: CGFloat?) -> [String] {
        let text = n.str("text") ?? n.str("value") ?? ""
        let font = textFont(n)
        let maxLines = max(1, Int(clamping: n.num("maxLines") ?? 1000))
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            guard let width, width > 0 else { lines.append(paragraph); continue }
            var current = ""
            for ch in paragraph {
                let candidate = current + String(ch)
                if !current.isEmpty && textWidth(candidate, font) > width { lines.append(current); current = String(ch) } else { current = candidate }
                if lines.count >= maxLines { break }
            }
            lines.append(current)
            if lines.count >= maxLines { break }
        }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
        }
        return lines
    }

    func textWidth(_ s: String, _ font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(AappCanvas.line(s, font: font, color: CGColor(gray: 1, alpha: 1)), nil, nil, nil))
    }
    func lineHeight(_ font: CTFont) -> CGFloat { ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) }

    /// Size a node wants inside the available space.
    func measure(_ n: MicroNode, maxWidth: CGFloat, maxHeight: CGFloat, depth: Int = 0) -> CGSize {
        guard depth < 256 else { return .zero }
        let pad = padding(n)
        let fixedW = dimension(n, "width", available: maxWidth), fixedH = dimension(n, "height", available: maxHeight)
        let innerMaxW = max(0, (fixedW ?? maxWidth) - pad.l - pad.r), innerMaxH = max(0, (fixedH ?? maxHeight) - pad.t - pad.b)
        var content = CGSize.zero
        let kids = visibleChildren(n)
        switch n.type {
        case "Text", "TextField", "MarkdownView", "SourceCode":
            let font = textFont(n)
            let lines = textLines(n, width: fixedW == nil ? innerMaxW : innerMaxW)
            content = CGSize(width: min(innerMaxW, ceil(lines.map { textWidth($0, font) }.max() ?? 0)),
                             height: lineHeight(font) * CGFloat(max(1, lines.count)))
        case "Image":
            if let res = n.str("res") ?? n.str("src"), let size = imageSize(res) { content = CGSize(width: min(size.width, innerMaxW), height: min(size.height, innerMaxH)) }
            else { content = CGSize(width: min(48, innerMaxW), height: min(48, innerMaxH)) }
        case "Space":
            let s = CGFloat(n.num("spaceSize") ?? n.num("size") ?? 8)
            content = CGSize(width: s, height: s)
        case "Custom":
            if let c = n.custom { content = CGSize(width: c.width, height: c.height) }
        case "Progress": content = CGSize(width: innerMaxW, height: 6)
        case "WheelPicker":
            content = CGSize(width: min(innerMaxW, 88), height: WheelState.rowHeight * CGFloat(wheel(n.id)?.visible ?? 3))
        case "Slider": content = CGSize(width: innerMaxW, height: 20)
        case _ where Self.columnTypes.contains(n.type) || n.type == "Scroll":
            var total: CGFloat = 0, widest: CGFloat = 0
            for (i, child) in kids.enumerated() {
                let s = measure(child, maxWidth: innerMaxW, maxHeight: max(0, innerMaxH - total), depth: depth + 1)
                total += s.height + (i > 0 ? spacing(n) : 0); widest = max(widest, s.width)
            }
            content = CGSize(width: widest, height: total)
        case _ where Self.rowTypes.contains(n.type):
            var total: CGFloat = 0, tallest: CGFloat = 0
            for (i, child) in kids.enumerated() {
                let s = measure(child, maxWidth: max(0, innerMaxW - total), maxHeight: innerMaxH, depth: depth + 1)
                total += s.width + (i > 0 ? spacing(n) : 0); tallest = max(tallest, s.height)
            }
            content = CGSize(width: total, height: tallest)
        default:
            for child in kids {
                let s = measure(child, maxWidth: innerMaxW, maxHeight: innerMaxH, depth: depth + 1)
                content = CGSize(width: max(content.width, s.width), height: max(content.height, s.height))
            }
            if kids.isEmpty && !Self.containerTypes.contains(n.type) && !Self.knownLeaf.contains(n.type) {
                content = CGSize(width: min(innerMaxW, 80), height: min(innerMaxH, 24))
            }
        }
        let w = fixedW ?? min(maxWidth, content.width + pad.l + pad.r)
        let h = fixedH ?? min(maxHeight, content.height + pad.t + pad.b)
        return CGSize(width: max(0, w), height: max(0, h))
    }

    var imageSize: (String) -> CGSize? = { _ in nil }

    /// Scroll offsets of Scroll/Lazy containers (main axis), kept so the focused node stays in view.
    private var scrollOffsets: [UInt32: CGFloat] = [:]

    func isScroller(_ n: MicroNode) -> Bool { n.type == "Scroll" || ["LazyColumn", "LazyRow", "LazyGrid"].contains(n.type) }
    private func horizontalScroll(_ n: MicroNode) -> Bool { n.type == "LazyRow" || n.str("scrollAxis") == "horizontal" }

    func layout(width: CGFloat, height: CGFloat) {
        guard let root, let node = nodes[root] else { return }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        place(node, bounds, depth: 0)
        normaliseFocus()
        // Scroll the nearest scrolling ancestor of the focused node so it is fully visible, then lay out again.
        guard let focused, let target = nodes[focused] else { return }
        var cursor = target.parent, steps = 0
        while let id = cursor, let ancestor = nodes[id], steps < 256 {
            steps += 1
            if isScroller(ancestor) {
                let pad = padding(ancestor)
                let f = ancestor.frame
                let view = CGRect(x: f.minX + pad.l, y: f.minY + pad.t, width: max(0, f.width - pad.l - pad.r), height: max(0, f.height - pad.t - pad.b))
                let horizontal = horizontalScroll(ancestor)
                let (lo, hi, vlo, vhi) = horizontal ? (target.frame.minX, target.frame.maxX, view.minX, view.maxX)
                                                    : (target.frame.minY, target.frame.maxY, view.minY, view.maxY)
                var offset = scrollOffsets[id] ?? 0
                if hi > vhi { offset += min(hi - vhi, lo - vlo) } else if lo < vlo { offset -= vlo - lo }
                offset = max(0, offset)
                if offset != (scrollOffsets[id] ?? 0) { scrollOffsets[id] = offset; place(node, bounds, depth: 0) }
                break
            }
            cursor = ancestor.parent
        }
    }

    private func place(_ n: MicroNode, _ rect: CGRect, depth: Int) {
        n.frame = rect
        guard depth < 256 else { return }
        let pad = padding(n)
        let inner = CGRect(x: rect.minX + pad.l, y: rect.minY + pad.t,
                           width: max(0, rect.width - pad.l - pad.r), height: max(0, rect.height - pad.t - pad.b))
        let kids = visibleChildren(n)
        guard !kids.isEmpty else { return }
        let scroller = isScroller(n)
        let vertical = Self.columnTypes.contains(n.type) || n.type == "Scroll" && !horizontalScroll(n)
        let horizontal = Self.rowTypes.contains(n.type) || n.type == "Scroll" && horizontalScroll(n)
        if vertical || horizontal {
            let gap = spacing(n)
            var sizes: [CGSize] = []
            var used: CGFloat = 0
            for child in kids {
                // Scrolling content is not limited by the viewport along the scroll axis.
                let s = vertical ? measure(child, maxWidth: inner.width, maxHeight: scroller ? 100_000 : max(0, inner.height - used), depth: depth + 1)
                                 : measure(child, maxWidth: scroller ? 100_000 : max(0, inner.width - used), maxHeight: inner.height, depth: depth + 1)
                sizes.append(s); used += (vertical ? s.height : s.width)
            }
            used += gap * CGFloat(max(0, kids.count - 1))
            let mainLength = vertical ? inner.height : inner.width
            let free = max(0, mainLength - used)
            var start: CGFloat = 0, between = gap
            switch (n.str("justify") ?? "start").lowercased() {
            case "center": start = free / 2
            case "end", "bottom", "right": start = free
            case "between", "spacebetween", "space-between": between = kids.count > 1 ? gap + free / CGFloat(kids.count - 1) : gap
            case "around", "spacearound", "space-around":
                let each = free / CGFloat(kids.count); start = each / 2; between = gap + each
            case "evenly", "spaceevenly", "space-evenly":
                let each = free / CGFloat(kids.count + 1); start = each; between = gap + each
            default: break
            }
            var cursor = start - (scroller ? scrollOffsets[n.id] ?? 0 : 0)
            let align = (n.str("align") ?? "start").lowercased()
            for (child, size) in zip(kids, sizes) {
                let cross = vertical ? inner.width : inner.height
                var length = vertical ? size.width : size.height
                let childAlign = (child.str("alignSelf") ?? align).lowercased()
                if childAlign == "stretch" { length = cross }
                let offset: CGFloat = childAlign == "center" ? (cross - length) / 2 : (["end", "bottom", "right"].contains(childAlign) ? cross - length : 0)
                let box = vertical
                    ? CGRect(x: inner.minX + offset, y: inner.minY + cursor, width: length, height: size.height)
                    : CGRect(x: inner.minX + cursor, y: inner.minY + offset, width: size.width, height: length)
                place(child, box, depth: depth + 1)
                cursor += (vertical ? size.height : size.width) + between
            }
        } else {
            // Stack-like: every child placed by the container's gravity. Stack centres by default (Host spec); a
            // Button's content starts top-left, as on the official simulator.
            let gravity = (n.str("gravity") ?? (n.type == "Stack" ? "center" : "topStart")).lowercased()
            for child in kids {
                let s = measure(child, maxWidth: inner.width, maxHeight: inner.height, depth: depth + 1)
                place(child, Self.gravityRect(gravity, size: s, in: inner), depth: depth + 1)
            }
        }
    }

    static func gravityRect(_ gravity: String, size: CGSize, in box: CGRect) -> CGRect {
        let g = gravity.lowercased()
        let x: CGFloat = g.hasSuffix("end") || g == "right" ? box.maxX - size.width
            : (g == "center" || g.hasSuffix("center") || g == "top" || g == "bottom") ? box.midX - size.width / 2 : box.minX
        let y: CGFloat = g.hasPrefix("bottom") ? box.maxY - size.height
            : (g == "center" || g.hasPrefix("center") || g == "start" || g == "end" || g == "left" || g == "right") ? box.midY - size.height / 2 : box.minY
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: focus

    func isFocusable(_ n: MicroNode) -> Bool {
        if n.flag("disabled") == true { return false }
        if let f = n.flag("focusable") { return f }
        return Self.focusableTypes.contains(n.type) || n.events.contains("click")
    }

    /// Focusable nodes in paint order.
    func focusables() -> [MicroNode] {
        guard let root, let r = nodes[root] else { return [] }
        var out: [MicroNode] = [], stack = [r], visited = 0
        while let n = stack.popLast(), visited < Self.maxNodes {
            visited += 1
            // A focusable scroll container is a stop only when nothing inside it can take focus.
            if n.id != root && isFocusable(n) && !(isScroller(n) && hasFocusableDescendant(n)) { out.append(n) }
            stack.append(contentsOf: visibleChildren(n).reversed())
        }
        return out
    }

    private func hasFocusableDescendant(_ n: MicroNode) -> Bool {
        var stack = visibleChildren(n), visited = 0
        while let c = stack.popLast(), visited < Self.maxNodes {
            visited += 1
            if isFocusable(c) { return true }
            stack.append(contentsOf: visibleChildren(c))
        }
        return false
    }

    /// Ensures something is focused if anything can be.
    func normaliseFocus() {
        let list = focusables()
        if let focused, list.contains(where: { $0.id == focused }) { return }
        focused = list.first?.id
    }

    /// Moves focus; returns false when nothing can take focus.
    @discardableResult func moveFocus(_ step: Int) -> Bool {
        let list = focusables()
        guard !list.isEmpty else { focused = nil; return false }
        let index = list.firstIndex { $0.id == focused } ?? (step > 0 ? -1 : list.count)
        let wraps = root.flatMap { nodes[$0]?.flag("focusWrapEnabled") } ?? true
        let next = index + step
        if !wraps && (next < 0 || next >= list.count) { return true }   // stays on the first/last item
        focused = list[(next + list.count * 2) % list.count].id
        return true
    }

    // MARK: painting

    static func color(_ value: MicroValue?) -> CGColor? {
        switch value {
        case .number(let n):
            guard n.isFinite, n >= 0, n <= Double(UInt32.max) else { return nil }
            let v = UInt32(n)
            return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: CGFloat((v >> 24) & 0xff) / 255)
        case .string(let s):
            let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
            guard let v = UInt32(hex, radix: 16) else { return nil }
            if hex.count == 6 { return CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1) }
            if hex.count == 8 { return color(.number(Double(v))) }
            return nil
        default: return nil
        }
    }

    private func radii(_ n: MicroNode) -> ADRFRadii {
        let all = Float(n.num("borderRadius") ?? 0)
        return ADRFRadii(topLeft: Float(n.num("borderTopLeftRadius") ?? Double(all)), topRight: Float(n.num("borderTopRightRadius") ?? Double(all)),
                         bottomRight: Float(n.num("borderBottomRightRadius") ?? Double(all)), bottomLeft: Float(n.num("borderBottomLeftRadius") ?? Double(all)))
    }

    func paint(in ctx: CGContext, resources: AappResources) {
        guard let root, let r = nodes[root] else { return }
        paint(r, ctx, resources, depth: 0)
    }

    private func paint(_ n: MicroNode, _ ctx: CGContext, _ resources: AappResources, depth: Int) {
        guard depth < 256 else { return }
        let rect = n.frame
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Transforms about the node's centre.
        let opacity = n.num("opacity") ?? 1
        if opacity < 1 { ctx.setAlpha(CGFloat(max(0, opacity))) }
        let tx = n.num("translateX") ?? 0, ty = n.num("translateY") ?? 0
        let sx = n.num("scaleX") ?? 1, sy = n.num("scaleY") ?? 1, rot = n.num("rotation") ?? 0
        if tx != 0 || ty != 0 || sx != 1 || sy != 1 || rot != 0 {
            ctx.translateBy(x: rect.midX + tx, y: rect.midY + ty)
            ctx.rotate(by: CGFloat(rot * .pi / 180))
            ctx.scaleBy(x: sx, y: sy)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }
        let isFocused = n.id == focused
        let shape = AappCanvas.roundedRect(rect, radii(n))
        let background = n.flag("disabled") == true ? (Self.color(n.props["backgroundDisabled"]) ?? Self.color(n.props["background"]))
            : isFocused ? (Self.color(n.props["backgroundFocused"]) ?? Self.color(n.props["background"])) : Self.color(n.props["background"])
        if let background { ctx.addPath(shape); ctx.setFillColor(background); ctx.fillPath() }
        if isFocused && n.props["backgroundFocused"] == nil {
            // Focus ring like the glasses UI when the app gave no focused background.
            ctx.addPath(AappCanvas.roundedRect(rect.insetBy(dx: 1, dy: 1), radii(n)))
            ctx.setStrokeColor(CGColor(srgbRed: 0.55, green: 1, blue: 0.6, alpha: 1)); ctx.setLineWidth(2); ctx.strokePath()
        }
        let pad = padding(n)
        let inner = CGRect(x: rect.minX + pad.l, y: rect.minY + pad.t, width: max(0, rect.width - pad.l - pad.r), height: max(0, rect.height - pad.t - pad.b))
        switch n.type {
        case "Text", "TextField", "MarkdownView", "SourceCode":
            let font = textFont(n)
            let color = Self.color(n.props["textColor"]) ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let lines = textLines(n, width: inner.width)
            let lh = lineHeight(font)
            let block = CGSize(width: lines.map { textWidth($0, font) }.max() ?? 0, height: lh * CGFloat(lines.count))
            let gravity = (n.str("gravity") ?? (n.type == "TextField" ? "centerStart" : "topStart"))
            let textAlign = (n.str("textAlign") ?? n.str("align") ?? "").lowercased()
            let origin = Self.gravityRect(gravity, size: block, in: inner).origin
            ctx.saveGState(); ctx.clip(to: rect)
            for (i, line) in lines.enumerated() {
                let w = textWidth(line, font)
                let x = textAlign == "center" ? origin.x + (block.width - w) / 2 : textAlign == "end" || textAlign == "right" ? origin.x + block.width - w : origin.x
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: x, y: origin.y + CGFloat(i) * lh + CTFontGetAscent(font))
                CTLineDraw(AappCanvas.line(line, font: font, color: color), ctx)
                ctx.restoreGState()
            }
            ctx.restoreGState()
        case "Image":
            if let res = n.str("res") ?? n.str("src"), let image = resources.image(res) {
                let fit: Int
                switch (n.str("fit") ?? "fill").lowercased() {
                case "fit", "contain": fit = 1
                case "crop", "cover": fit = 2
                case "center", "none": fit = 3
                case "scale", "scaledown": fit = 4
                default: fit = 0
                }
                ctx.saveGState(); ctx.addPath(shape); ctx.clip()
                AappCanvas.drawImage(image, in: inner, fit: fit, align: 1, justify: 1, ctx: ctx)
                ctx.restoreGState()
            } else {
                warn("micro：图片资源缺失（节点 \(n.id)，\(n.str("res") ?? "无 res")）")
                AappCanvas.placeholder(inner, label: "Image", ctx: ctx)
            }
        case "Custom":
            if let c = n.custom, c.frame.width > 0, c.frame.height > 0 {
                ctx.saveGState(); ctx.clip(to: rect)
                let kx = inner.width / CGFloat(c.frame.width), ky = inner.height / CGFloat(c.frame.height)
                ctx.translateBy(x: inner.minX, y: inner.minY)
                switch c.mode {
                case 1: let k = min(kx, ky); ctx.translateBy(x: (inner.width - CGFloat(c.frame.width) * k) / 2, y: (inner.height - CGFloat(c.frame.height) * k) / 2); ctx.scaleBy(x: k, y: k)
                case 2: ctx.scaleBy(x: kx, y: ky)
                default: break
                }
                AappCanvas.draw(c.frame, in: ctx, resources: resources, warn: warn)
                ctx.restoreGState()
            }
        case "WheelPicker":
            guard let wheel = wheel(n.id), !wheel.labels.isEmpty else { AappCanvas.placeholder(inner, label: "WheelPicker", ctx: ctx); break }
            ctx.saveGState(); ctx.clip(to: rect)
            let rows = wheel.visible, middle = rows / 2
            let font = AappCanvas.font(nil, size: 18)
            let top = inner.midY - WheelState.rowHeight * CGFloat(rows) / 2
            let band = CGRect(x: inner.minX, y: top + WheelState.rowHeight * CGFloat(middle), width: inner.width, height: WheelState.rowHeight)
            ctx.setFillColor(wheel.editing ? CGColor(srgbRed: 0.3, green: 0.6, blue: 0.4, alpha: 0.95) : CGColor(srgbRed: 0.2, green: 0.35, blue: 0.27, alpha: 0.9))
            ctx.addPath(AappCanvas.roundedRect(band, ADRFRadii(topLeft: 6, topRight: 6, bottomRight: 6, bottomLeft: 6))); ctx.fillPath()
            for row in 0..<rows {
                let offset = row - middle
                guard let label = wheel.label(at: max(0, wheel.index) + offset) else { continue }
                let alpha = offset == 0 ? 1 : max(0.25, 0.75 - 0.2 * Double(abs(offset)))
                let color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
                let w = textWidth(label, font)
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: inner.midX - w / 2, y: top + WheelState.rowHeight * CGFloat(row) + (WheelState.rowHeight - lineHeight(font)) / 2 + CTFontGetAscent(font))
                CTLineDraw(AappCanvas.line(label, font: font, color: color), ctx)
                ctx.restoreGState()
            }
            ctx.restoreGState()
        case "Progress", "Slider":
            var value = n.num("progress") ?? n.num("value") ?? 0
            let maxValue = n.num("max") ?? (value > 1 ? 100 : 1)
            value = maxValue > 0 ? max(0, min(1, value / maxValue)) : 0
            let track = CGRect(x: inner.minX, y: inner.midY - 3, width: inner.width, height: 6)
            ctx.addPath(AappCanvas.roundedRect(track, ADRFRadii(topLeft: 3, topRight: 3, bottomRight: 3, bottomLeft: 3)))
            ctx.setFillColor(Self.color(n.props["trackColor"]) ?? CGColor(srgbRed: 0.2, green: 0.3, blue: 0.22, alpha: 1)); ctx.fillPath()
            let filled = CGRect(x: track.minX, y: track.minY, width: track.width * value, height: track.height)
            ctx.addPath(AappCanvas.roundedRect(filled, ADRFRadii(topLeft: 3, topRight: 3, bottomRight: 3, bottomLeft: 3)))
            ctx.setFillColor(Self.color(n.props["color"]) ?? Self.color(n.props["textColor"]) ?? CGColor(srgbRed: 0.4, green: 1, blue: 0.5, alpha: 1)); ctx.fillPath()
        default:
            if visibleChildren(n).isEmpty && !Self.containerTypes.contains(n.type) && !Self.knownLeaf.contains(n.type)
                && !Self.columnTypes.contains(n.type) && !Self.rowTypes.contains(n.type) && n.type != "Scroll" {
                warn("micro：组件「\(n.type)」暂不支持，显示为占位框")
                AappCanvas.placeholder(rect, label: n.type, ctx: ctx)
            }
        }
        let clips = isScroller(n) || n.flag("clip") == true
        if clips { ctx.addPath(shape); ctx.clip() }
        for child in visibleChildren(n) { paint(child, ctx, resources, depth: depth + 1) }
    }
}

/// WheelPicker state, mirroring the Host's ShadowWheelState: configured from `wheelConfig` JSON
/// ({"items":[{"value","label"}], "value", "loop", "visibleCount", "version", "revision"}); Enter starts/ends
/// adjusting, ↑/↓ move while adjusting, and every change is reported as a `wheel` component event.
final class WheelState {
    static let rowHeight: CGFloat = 36
    var labels: [String] = []
    var values: [Any] = []
    var index = -1, version = 0, revision = 0, visible = 3
    var loop = false, editing = false
    var emptyValue: Any = NSNull()

    func configure(_ n: MicroNode) {
        guard let text = n.str("wheelConfig"), let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { labels = []; values = []; index = -1; return }
        labels = []; values = []
        for item in (json["items"] as? [[String: Any]]) ?? [] {
            labels.append((item["label"] as? String) ?? "\(item["value"] ?? "")")
            values.append(item["value"] ?? NSNull())
        }
        if let restored = (json["revision"] as? NSNumber)?.intValue, restored > revision { revision = restored }
        emptyValue = json["value"] ?? NSNull()
        index = values.firstIndex { "\($0)" == "\(emptyValue)" } ?? -1
        version = (json["version"] as? NSNumber)?.intValue ?? 0
        loop = (json["loop"] as? Bool) ?? false
        visible = max(1, min(9, (json["visibleCount"] as? NSNumber)?.intValue ?? 3))
    }

    /// Moves the selection; false when it cannot move (end of a non-looping list, or empty).
    func move(_ steps: Int) -> Int? {
        guard !values.isEmpty else { return nil }
        let base = max(0, index)
        let next = loop ? ((base + steps) % values.count + values.count) % values.count : min(max(base + steps, 0), values.count - 1)
        guard next != index else { return nil }
        let delta = loop ? steps : next - base
        index = next
        return delta
    }

    func event(phase: String, source: String, delta: Int = 0) -> [String: Any] {
        revision += 1
        return ["value": index >= 0 && index < values.count ? values[index] : emptyValue, "index": index, "itemCount": values.count,
                "version": version, "revision": revision, "phase": phase, "source": source, "delta": delta,
                "adjusting": editing, "settled": true,
                "canDecrease": index >= 0 && (loop ? values.count > 1 : index > 0),
                "canIncrease": index >= 0 && (loop ? values.count > 1 : index < values.count - 1)]
    }

    func label(at i: Int) -> String? {
        guard !labels.isEmpty else { return nil }
        if loop { return labels[((i % labels.count) + labels.count) % labels.count] }
        return labels.indices.contains(i) ? labels[i] : nil
    }
}

extension Int {
    /// Nearest Int for any Double (NaN → 0, ±∞ and huge values clamp), never trapping on app-supplied numbers.
    init(clamping d: Double) {
        if d.isNaN { self = 0 } else if d >= Double(Int.max) { self = .max } else if d <= Double(Int.min) { self = .min } else { self = Int(d) }
    }
}

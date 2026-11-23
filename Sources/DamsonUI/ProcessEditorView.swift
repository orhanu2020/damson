import SwiftUI
import DamsonCore

/// The project's process as an n8n-style canvas: a tile per step, connected by arrows. Steps that can report a
/// failure (review, test, deploy ...) have two outputs, pass and fail. Drag a tile to move it, drag from a dot on any
/// side to another tile to connect, or press the + at an open output to add the next step. Everything about a step,
/// note or arrow is changed in the settings panel on the right.
struct ProcessEditorView: View {
    @ObservedObject var model: AppModel
    let project: Project

    enum Selection: Equatable { case step(String), note(String), edge(String) }
    @State private var sel: Selection?
    /// Several steps and notes selected together ("s:<id>" / "n:<id>"): by shift-click or by dragging a region.
    @State private var picked: Set<String> = []
    @State private var marquee: (start: CGPoint, current: CGPoint)?
    @FocusState private var canvasFocus: Bool
    @State private var noteStart: [String: CGPoint] = [:]
    @State private var noteMoving: [String: CGPoint] = [:]
    @State private var noteResizing: [String: CGSize] = [:]
    @State private var dragStart: [String: CGPoint] = [:]
    @State private var dragging: [String: CGPoint] = [:]
    /// A connection being drawn from a dot, or an end of an arrow being moved.
    @State private var connecting: (from: String, condition: EdgeCondition, side: FlowSide, to: CGPoint)?
    @State private var movingEnd: (edge: String, end: End, to: CGPoint)?
    @State private var confirmReset = false
    @State private var rejectedConnection = false
    @State private var zoom: CGFloat = 1
    @State private var available = CGSize(width: 900, height: 500)
    @AppStorage("processPanelWidth") private var panelWidth: Double = 340
    @State private var panelStart: Double?

    enum End { case start, finish }

    static let tile = CGSize(width: 104, height: 104)

    private var running: Bool { model.isRunning(project.id) }

    private func origin(_ step: FlowStep) -> CGPoint { dragging[step.id] ?? CGPoint(x: step.x, y: step.y) }
    private func rect(_ step: FlowStep) -> CGRect { CGRect(origin: origin(step), size: Self.tile) }

    /// Review, test, deploy ... can pass or fail, so they get two outputs.
    private func branches(_ step: FlowStep) -> Bool { step.kind.branches }

    private var selectedStepID: String? { if case .step(let id) = sel { return id } else { return nil } }
    private func noteOrigin(_ n: FlowNote) -> CGPoint { noteMoving[n.id] ?? CGPoint(x: n.x, y: n.y) }
    private func noteSize(_ n: FlowNote) -> CGSize { noteResizing[n.id] ?? CGSize(width: n.width, height: n.height) }

    private var shiftHeld: Bool { NSEvent.modifierFlags.contains(.shift) }
    private var hasSelection: Bool { sel != nil || !picked.isEmpty }
    private func isPicked(_ key: String) -> Bool { picked.contains(key) }

    /// Selects one thing, or with shift adds it to / removes it from the group.
    private func choose(_ key: String, as single: Selection) {
        guard shiftHeld else { sel = single; picked = []; return }
        var group = picked
        if group.isEmpty, let current = sel {
            switch current {
            case .step(let id): group.insert("s:" + id)
            case .note(let id): group.insert("n:" + id)
            case .edge: break
            }
        }
        if group.contains(key) { group.remove(key) } else { group.insert(key) }
        setGroup(group)
    }

    private func setGroup(_ group: Set<String>) {
        if group.count > 1 { picked = group; sel = nil; return }
        picked = []
        if let only = group.first {
            sel = only.hasPrefix("s:") ? .step(String(only.dropFirst(2))) : .note(String(only.dropFirst(2)))
        } else { sel = nil }
    }

    private func deleteSelection() {
        if picked.count > 1 {
            for key in picked {
                let id = String(key.dropFirst(2))
                if key.hasPrefix("s:") { if !running { model.removeStep(project.id, id) } } else { model.removeNote(project.id, id) }
            }
            picked = []; sel = nil
            return
        }
        switch sel {
        case .step(let id): if !running { model.removeStep(project.id, id) }
        case .note(let id): model.removeNote(project.id, id)
        case .edge(let id): if !running { model.setEdge(project.id, id, condition: nil) }
        case nil: return
        }
        sel = nil
    }

    private func duplicatePicked() {
        guard !running else { return }
        var created: Set<String> = []
        for key in picked {
            let id = String(key.dropFirst(2))
            if key.hasPrefix("s:") { if let n = model.duplicateStep(project.id, id) { created.insert("s:" + n) } }
            else if let note = project.notes.first(where: { $0.id == id }) {
                let n = model.addNote(project.id, at: CGPoint(x: note.x + 40, y: note.y + 40))
                model.editNote(project.id, n) { $0.text = note.text; $0.color = note.color; $0.width = note.width; $0.height = note.height }
                created.insert("n:" + n)
            }
        }
        setGroup(created)
    }

    /// Lines the picked items up on their left or top edge.
    private func align(vertical: Bool) {
        var xs: [Double] = [], ys: [Double] = []
        for key in picked {
            let id = String(key.dropFirst(2))
            if key.hasPrefix("s:"), let st = project.step(id) { xs.append(st.x); ys.append(st.y) }
            else if let n = project.notes.first(where: { $0.id == id }) { xs.append(n.x); ys.append(n.y) }
        }
        guard let minX = xs.min(), let minY = ys.min() else { return }
        for key in picked {
            let id = String(key.dropFirst(2))
            if key.hasPrefix("s:"), let st = project.step(id) {
                model.moveStep(project.id, id, to: CGPoint(x: vertical ? minX : st.x, y: vertical ? st.y : minY))
            } else if let n = project.notes.first(where: { $0.id == id }) {
                model.editNote(project.id, id) { if vertical { $0.x = minX } else { $0.y = minY } }
                _ = n
            }
        }
    }

    /// Moves everything picked together while one of them is dragged.
    private func dragGroup(by t: CGSize) {
        for key in picked {
            let id = String(key.dropFirst(2))
            if key.hasPrefix("s:"), let st = project.step(id) {
                let start = dragStart[id] ?? CGPoint(x: st.x, y: st.y); dragStart[id] = start
                dragging[id] = CGPoint(x: max(0, start.x + t.width), y: max(0, start.y + t.height))
            } else if let n = project.notes.first(where: { $0.id == id }) {
                let start = noteStart[id] ?? CGPoint(x: n.x, y: n.y); noteStart[id] = start
                noteMoving[id] = CGPoint(x: max(0, start.x + t.width), y: max(0, start.y + t.height))
            }
        }
    }

    private func endGroupDrag() {
        for (id, p) in dragging { model.moveStep(project.id, id, to: p) }
        for (id, p) in noteMoving { model.editNote(project.id, id) { $0.x = p.x; $0.y = p.y } }
        dragging = [:]; dragStart = [:]; noteMoving = [:]; noteStart = [:]
    }

    private func finishMarquee(_ r: CGRect) {
        var group: Set<String> = shiftHeld ? picked : []
        if shiftHeld, group.isEmpty, let current = sel {
            switch current {
            case .step(let id): group.insert("s:" + id)
            case .note(let id): group.insert("n:" + id)
            case .edge: break
            }
        }
        for st in project.steps where rect(st).intersects(r) { group.insert("s:" + st.id) }
        for n in project.notes where CGRect(origin: noteOrigin(n), size: noteSize(n)).intersects(r) { group.insert("n:" + n.id) }
        setGroup(group)
    }

    // MARK: Ports

    private func dir(_ side: FlowSide) -> CGPoint {
        switch side {
        case .right: return CGPoint(x: 1, y: 0)
        case .left: return CGPoint(x: -1, y: 0)
        case .top: return CGPoint(x: 0, y: -1)
        case .bottom: return CGPoint(x: 0, y: 1)
        }
    }

    /// Where an arrow meets a step on a side. The right side of a branching step has two dots (pass and fail).
    private func port(_ step: FlowStep, _ side: FlowSide, condition: EdgeCondition = .always) -> CGPoint {
        let r = rect(step)
        switch side {
        case .right: return branches(step) ? CGPoint(x: r.maxX, y: r.minY + (condition == .fail ? 76 : 28)) : CGPoint(x: r.maxX, y: r.midY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        }
    }

    private func start(_ edge: FlowEdge, _ a: FlowStep) -> (point: CGPoint, side: FlowSide) {
        let side = edge.fromSide ?? .right
        return (port(a, side, condition: edge.condition), side)
    }
    private func finish(_ edge: FlowEdge, _ b: FlowStep) -> (point: CGPoint, side: FlowSide) {
        let side = edge.toSide ?? .left
        return (port(b, side), side)
    }

    /// The side of a step nearest to a point (used when dropping an arrow on a step).
    private func nearestSide(_ step: FlowStep, to p: CGPoint) -> FlowSide {
        let r = rect(step)
        let dx = (p.x - r.midX) / r.width, dy = (p.y - r.midY) / r.height
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .bottom : .top
    }

    /// The outputs of a step that lead nowhere yet (they get a + button).
    private func openOutputs(_ step: FlowStep) -> [EdgeCondition] {
        let out = project.edges.filter { $0.from == step.id }
        if !branches(step) { return out.isEmpty ? [.always] : [] }
        var open: [EdgeCondition] = []
        if !out.contains(where: { $0.condition != .fail }) { open.append(.pass) }
        if !out.contains(where: { $0.condition == .fail }) { open.append(.fail) }
        return open
    }

    private var contentSize: CGSize {
        let noteX = project.notes.map { noteOrigin($0).x + noteSize($0).width }.max() ?? 0
        let noteY = project.notes.map { noteOrigin($0).y + noteSize($0).height }.max() ?? 0
        let maxX = max(noteX, project.steps.map { rect($0).maxX }.max() ?? 0)
        let maxY = max(noteY, project.steps.map { rect($0).maxY }.max() ?? 0)
        return CGSize(width: max(900, maxX + 260), height: max(460, maxY + 280))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            HStack(alignment: .top, spacing: 0) {
                canvas
                panelHandle
                inspector.frame(width: CGFloat(panelWidth))
            }
        }
        .confirmationDialog("Replace this process with the standard delivery process?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Replace and clear progress", role: .destructive) { sel = nil; model.resetProcess(project.id) }
        }
    }

    /// Drag to make the settings panel wider or narrower.
    private var panelHandle: some View {
        Rectangle().fill(Color.clear).frame(width: 12)
            .overlay(Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 4, height: 44))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let start = panelStart ?? panelWidth
                    panelStart = start
                    panelWidth = min(640, max(280, start - g.translation.width))
                }
                .onEnded { _ in panelStart = nil })
            .help("Drag to resize the settings panel")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(StepKind.palette.filter { $0 != .approval }, id: \.self) { kind in
                    Button { add(kind) } label: { Label(kind.label, systemImage: kind.icon) }
                }
            } label: { Label("Add step", systemImage: "plus.circle.fill") }
                .menuStyle(.borderlessButton).fixedSize().disabled(running)
            Button { add(.approval) } label: { Label("Human approval", systemImage: "hand.raised.fill") }
                .controlSize(.small).disabled(running).help("Add a gate only you can pass")
            Button { addNote() } label: { Label("Note", systemImage: "note.text") }
                .controlSize(.small).help("Add a free note to the canvas")
            Divider().frame(height: 16)
            Button {
                if picked.count > 1 { duplicatePicked() }
                else if let id = selectedStepID, let new = model.duplicateStep(project.id, id) { sel = .step(new) }
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .controlSize(.small).disabled(running || (selectedStepID == nil && picked.count < 2))
            Button(role: .destructive) { deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .controlSize(.small).disabled(!hasSelection || (running && selectedStepID != nil)).help("Delete what is selected (\u{232B})")
            Divider().frame(height: 16)
            Button { model.arrangeSteps(project.id) } label: { Label("Tidy up", systemImage: "square.grid.3x2") }
                .controlSize(.small).disabled(running).help("Put the steps back in rows")
            Button { confirmReset = true } label: { Label("Standard process", systemImage: "arrow.counterclockwise") }
                .controlSize(.small).disabled(running)
            Spacer()
            Text("Drag a region or shift-click to select several \u{00B7} drag from a dot to connect \u{00B7} change things on the right").font(.caption).foregroundStyle(.secondary)
        }
        .overlay(alignment: .bottomLeading) {
            if rejectedConnection {
                Text("That connection is not possible.").font(.caption).foregroundStyle(.orange).offset(y: 18)
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        if picked.count > 1 {
            MultiInspector(count: picked.count, steps: picked.filter { $0.hasPrefix("s:") }.count, running: running,
                           onDuplicate: duplicatePicked, onDelete: deleteSelection,
                           onAlignLeft: { align(vertical: true) }, onAlignTop: { align(vertical: false) },
                           onClear: { picked = [] })
        } else {
            singleInspector
        }
    }

    @ViewBuilder private var singleInspector: some View {
        switch sel {
        case .step(let id):
            if let step = project.step(id) {
                StepInspector(model: model, project: project, step: step, select: { sel = $0 })
            }
        case .note(let id):
            if let note = project.notes.first(where: { $0.id == id }) {
                NoteInspector(model: model, projectID: project.id, note: note, onRemove: { sel = nil })
            }
        case .edge(let id):
            if let edge = project.edges.first(where: { $0.id == id }) {
                EdgeInspector(model: model, project: project, edge: edge, select: { sel = $0 })
            }
        case nil:
            InspectorHelp()
        }
    }

    private func add(_ kind: StepKind) {
        // Below the lowest step, so a new step never lands on top of another one.
        let y = (project.steps.map { $0.y }.max() ?? 0) + ProjectFlow.rowHeight
        if let id = model.addStep(project.id, kind: kind, at: CGPoint(x: 40, y: y)) { sel = .step(id) }
    }

    private func addNote() {
        let y = (project.steps.map { $0.y }.max() ?? 0) + ProjectFlow.rowHeight
        sel = .note(model.addNote(project.id, at: CGPoint(x: 40, y: y)))
    }

    /// The + at an open output: a new step connected to that output.
    private func addAfter(_ step: FlowStep, _ condition: EdgeCondition, kind: StepKind) {
        let r = rect(step)
        let point = CGPoint(x: r.maxX + 110, y: r.minY + (condition == .fail ? ProjectFlow.rowHeight * 0.8 : 0))
        guard let id = model.addStep(project.id, kind: kind, at: point) else { return }
        model.connect(project.id, from: step.id, to: id, condition: condition)
        sel = .step(id)
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                content
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: contentSize.width * zoom, height: contentSize.height * zoom, alignment: .topLeading)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .focusable().focused($canvasFocus).focusEffectDisabled()
            .onDeleteCommand { deleteSelection() }
            .onChange(of: sel) { _, new in if new != nil { canvasFocus = true } }
            .overlay(alignment: .bottomLeading) { zoomControls(in: geo.size).padding(12) }
            .overlay(alignment: .bottom) { executeButton.padding(.bottom, 14) }
            .onAppear { available = geo.size }
            .onChange(of: geo.size) { _, new in available = new }
        }
        .frame(minHeight: 460)
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            // The empty canvas: click to deselect, drag to select everything inside the region.
            Color.clear.frame(width: contentSize.width, height: contentSize.height)
                .contentShape(Rectangle())
                .onTapGesture { sel = nil; picked = [] }
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("canvas"))
                    .onChanged { g in marquee = (g.startLocation, g.location) }
                    .onEnded { g in
                        let r = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                       width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
                        marquee = nil
                        finishMarquee(r)
                    })
            Canvas { context, size in
                // Dotted background.
                let dot = Color.primary.opacity(0.14)
                var y: CGFloat = 12
                while y < size.height {
                    var x: CGFloat = 12
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(dot))
                        x += 22
                    }
                    y += 22
                }
                for edge in project.edges {
                    guard let a = project.step(edge.from), let b = project.step(edge.to) else { continue }
                    let s = start(edge, a), f = finish(edge, b)
                    let chosen = sel == .edge(edge.id)
                    draw(context, from: s.point, fromSide: s.side, to: f.point, toSide: f.side, legacyLoop: edge.loop && edge.fromSide == nil && edge.toSide == nil,
                         color: chosen ? Theme.green : lineColor(edge), dashed: edge.loop, width: chosen ? 3 : 1.8)
                }
                // Short stubs from open outputs to their + buttons.
                for step in project.steps where !running {
                    for c in openOutputs(step) {
                        let p = port(step, .right, condition: c)
                        var stub = Path(); stub.move(to: p); stub.addLine(to: CGPoint(x: p.x + 26, y: p.y))
                        context.stroke(stub, with: .color(Color.secondary.opacity(0.6)), lineWidth: 1.6)
                    }
                }
                if let c = connecting, let a = project.step(c.from) {
                    draw(context, from: port(a, c.side, condition: c.condition), fromSide: c.side, to: c.to, toSide: nil, legacyLoop: false, color: Theme.green, dashed: true, width: 1.8)
                }
                if let m = movingEnd, let edge = project.edges.first(where: { $0.id == m.edge }), let a = project.step(edge.from), let b = project.step(edge.to) {
                    let s = start(edge, a), f = finish(edge, b)
                    if m.end == .finish { draw(context, from: s.point, fromSide: s.side, to: m.to, toSide: nil, legacyLoop: false, color: Theme.green, dashed: true, width: 2.4) }
                    else { draw(context, from: m.to, fromSide: nil, to: f.point, toSide: f.side, legacyLoop: false, color: Theme.green, dashed: true, width: 2.4) }
                }
            }
            .frame(width: contentSize.width, height: contentSize.height)
            .allowsHitTesting(false)

            ForEach(project.notes) { note in noteView(note) }
            ForEach(project.edges) { edge in
                if let a = project.step(edge.from), let b = project.step(edge.to) {
                    edgeHandle(edge, a, b)
                }
            }
            ForEach(project.steps) { step in
                node(step)
                if !running {
                    ForEach(openOutputs(step), id: \.self) { c in plusButton(step, c) }
                }
            }
            if case .edge(let id) = sel, !running, let edge = project.edges.first(where: { $0.id == id }),
               let a = project.step(edge.from), let b = project.step(edge.to) {
                endHandle(edge, .start, at: start(edge, a).point)
                endHandle(edge, .finish, at: finish(edge, b).point)
            }
        }
        .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
        .coordinateSpace(name: "canvas")
        .overlay(alignment: .topLeading) {
            if let m = marquee {
                let r = CGRect(x: min(m.start.x, m.current.x), y: min(m.start.y, m.current.y), width: abs(m.current.x - m.start.x), height: abs(m.current.y - m.start.y))
                Rectangle().fill(Theme.green.opacity(0.12))
                    .overlay(Rectangle().stroke(Theme.green, style: StrokeStyle(lineWidth: 1.2, dash: [5, 3])))
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY).allowsHitTesting(false)
            }
        }
    }

    private func lineColor(_ edge: FlowEdge) -> Color {
        switch edge.condition {
        case .always: return Color(white: 0.5)
        case .pass: return Color(white: 0.5)
        case .fail: return Color(red: 0.85, green: 0.3, blue: 0.3)
        }
    }

    /// The two control points of an arrow's curve. A loop back to an earlier step that has no chosen sides swings below.
    private func controls(_ a: CGPoint, _ fromSide: FlowSide?, _ b: CGPoint, _ toSide: FlowSide?, legacyLoop: Bool) -> (CGPoint, CGPoint) {
        if legacyLoop {
            let depth = max(a.y, b.y) + 90
            return (CGPoint(x: a.x + 70, y: depth), CGPoint(x: b.x - 70, y: depth))
        }
        let d = max(46, hypot(b.x - a.x, b.y - a.y) / 2.4)
        let da = fromSide.map(dir) ?? .zero, db = toSide.map(dir) ?? .zero
        let c1 = fromSide == nil ? a : CGPoint(x: a.x + da.x * d, y: a.y + da.y * d)
        let c2 = toSide == nil ? b : CGPoint(x: b.x + db.x * d, y: b.y + db.y * d)
        return (c1, c2)
    }

    private func midpoint(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: 0.125 * a.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * b.x, y: 0.125 * a.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * b.y)
    }

    private func draw(_ context: GraphicsContext, from a: CGPoint, fromSide: FlowSide?, to b: CGPoint, toSide: FlowSide?, legacyLoop: Bool, color: Color, dashed: Bool, width: CGFloat) {
        let (c1, c2) = controls(a, fromSide, b, toSide, legacyLoop: legacyLoop)
        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: c1, control2: c2)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dashed ? [6, 4] : []))
        // Arrow head along the end of the curve.
        var ux = b.x - c2.x, uy = b.y - c2.y
        let len = hypot(ux, uy)
        if len < 0.5 { ux = 1; uy = 0 } else { ux /= len; uy /= len }
        let tip = CGPoint(x: b.x - ux * 2, y: b.y - uy * 2)
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - ux * 11 - uy * 6, y: tip.y - uy * 11 + ux * 6))
        arrow.addLine(to: CGPoint(x: tip.x - ux * 11 + uy * 6, y: tip.y - uy * 11 - ux * 6))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    /// The mark on an arrow: click it to select the arrow (change it on the right). A selected arrow also shows a delete button.
    private func edgeHandle(_ edge: FlowEdge, _ a: FlowStep, _ b: FlowStep) -> some View {
        let chosen = sel == .edge(edge.id)
        let color = chosen ? Theme.green : lineColor(edge)
        let s = start(edge, a), f = finish(edge, b)
        let (c1, c2) = controls(s.point, s.side, f.point, f.side, legacyLoop: edge.loop && edge.fromSide == nil && edge.toSide == nil)
        let mid = midpoint(s.point, c1, c2, f.point)
        return ZStack {
            Button { sel = .edge(edge.id) } label: {
                if edge.loop || !edge.label.isEmpty {
                    Text((edge.loop ? "\u{21BB} \(edge.rounds)/\(ProjectFlow.maxLoops) " : "") + edge.label)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.card))
                        .overlay(Capsule().stroke(color.opacity(0.8), lineWidth: chosen ? 2 : 1))
                } else {
                    Circle().fill(Theme.card).frame(width: 14, height: 14).overlay(Circle().stroke(color, lineWidth: chosen ? 2.6 : 1.6))
                        .contentShape(Circle().inset(by: -7))
                }
            }
            .buttonStyle(.plain)
            .help("Select this arrow")
            if chosen && !running {
                Button { model.setEdge(project.id, edge.id, condition: nil); sel = nil } label: {
                    Image(systemName: "trash.fill").font(.system(size: 11)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(Circle().fill(Color.red))
                }
                .buttonStyle(.plain).offset(y: -26).help("Delete this arrow")
            }
        }
        .position(x: mid.x, y: mid.y)
    }

    /// A handle on an end of the selected arrow: drag it to another side or step to change where the arrow connects.
    private func endHandle(_ edge: FlowEdge, _ end: End, at p: CGPoint) -> some View {
        Circle().fill(Theme.green).frame(width: 15, height: 15)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2)
            .contentShape(Circle().inset(by: -8))
            .position(p)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { g in movingEnd = (edge.id, end, g.location) }
                .onEnded { g in
                    movingEnd = nil
                    guard let target = project.steps.first(where: { rect($0).insetBy(dx: -16, dy: -16).contains(g.location) }) else { return }
                    let side = nearestSide(target, to: g.location)
                    let newID: String?
                    if end == .finish { newID = model.reconnect(project.id, edge.id, to: target.id, fromSide: edge.fromSide, toSide: side) }
                    else { newID = model.reconnect(project.id, edge.id, from: target.id, fromSide: side, toSide: edge.toSide) }
                    if let newID { sel = .edge(newID) } else { flashRejected() }
                })
            .help(end == .finish ? "Drag to change where the arrow ends" : "Drag to change where the arrow starts")
    }

    private func flashRejected() {
        rejectedConnection = true
        Task { try? await Task.sleep(nanoseconds: 3_500_000_000); rejectedConnection = false }
    }

    private func plusButton(_ step: FlowStep, _ condition: EdgeCondition) -> some View {
        let p = port(step, .right, condition: condition)
        return Menu {
            ForEach(StepKind.palette, id: \.self) { kind in
                Button { addAfter(step, condition, kind: kind) } label: { Label(kind.label, systemImage: kind.icon) }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.6), lineWidth: 1.2))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .position(x: p.x + 38, y: p.y)
        .help("Add the next step")
    }

    // MARK: Notes

    private func noteColor(_ c: FlowNote.Color) -> Color { NoteStyle.fill(c) }

    private func noteView(_ note: FlowNote) -> some View {
        let origin = noteOrigin(note), size = noteSize(note)
        let chosen = sel == .note(note.id) || isPicked("n:" + note.id)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(noteColor(note.color))
                .shadow(color: .black.opacity(0.15), radius: chosen ? 6 : 2, y: 1)
            RoundedRectangle(cornerRadius: 8).stroke(chosen ? Theme.green : Color.black.opacity(0.12), lineWidth: chosen ? 2.5 : 1)
            Text(note.text.isEmpty ? "Empty note. Select it to write." : note.text)
                .font(.system(size: 14)).foregroundStyle(Color.black.opacity(note.text.isEmpty ? 0.4 : 0.8))
                .padding(10).frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 10)).foregroundStyle(Color.black.opacity(0.35))
                .frame(width: 24, height: 24).contentShape(Rectangle())
                .position(x: size.width - 12, y: size.height - 12)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                    .onChanged { g in
                        noteResizing[note.id] = CGSize(width: max(100, note.width + g.translation.width), height: max(60, note.height + g.translation.height))
                    }
                    .onEnded { _ in
                        if let r = noteResizing[note.id] { model.editNote(project.id, note.id) { $0.width = r.width; $0.height = r.height } }
                        noteResizing[note.id] = nil
                    })
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { g in
                if picked.count > 1 && isPicked("n:" + note.id) { dragGroup(by: g.translation); return }
                if !picked.isEmpty { picked = [] }
                let start = noteStart[note.id] ?? CGPoint(x: note.x, y: note.y)
                noteStart[note.id] = start
                noteMoving[note.id] = CGPoint(x: max(0, start.x + g.translation.width), y: max(0, start.y + g.translation.height))
                sel = .note(note.id)
            }
            .onEnded { _ in endGroupDrag() })
        .onTapGesture { choose("n:" + note.id, as: .note(note.id)) }
        .offset(x: origin.x, y: origin.y)
    }

    // MARK: Steps

    private func node(_ step: FlowStep) -> some View {
        let box = rect(step)
        let isSelected = sel == .step(step.id) || isPicked("s:" + step.id)
        let tint: Color = step.kind == .approval ? .orange : (step.kind == .task ? Color.indigo : Theme.green)
        let isStart = !project.edges.contains { !$0.loop && $0.to == step.id }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18).fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(isSelected ? Theme.green : borderColor(step.status), lineWidth: isSelected ? 3 : 1.5))
                .shadow(color: .black.opacity(isSelected ? 0.22 : 0.10), radius: isSelected ? 6 : 2, y: 1)
                .frame(width: box.width, height: box.height)
            Image(systemName: step.kind.icon).font(.system(size: 38)).foregroundStyle(tint)
                .frame(width: box.width, height: box.height)
            statusBadge(step.status).position(x: box.width - 16, y: box.height - 16)
            if isStart {
                Image(systemName: "bolt.fill").font(.system(size: 16)).foregroundStyle(.primary)
                    .position(x: -28, y: box.height / 2)
            }
            // A dot on every side: drag from one to another step to connect.
            sideDot(step, .left)
            sideDot(step, .top)
            sideDot(step, .bottom)
            if branches(step) {
                outputDot(step, .right, .pass, y: 28, label: "pass")
                outputDot(step, .right, .fail, y: 76, label: "fail")
            } else {
                sideDot(step, .right)
            }
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { g in
                if picked.count > 1 && isPicked("s:" + step.id) { dragGroup(by: g.translation); return }
                if !picked.isEmpty { picked = [] }
                let start = dragStart[step.id] ?? CGPoint(x: step.x, y: step.y)
                dragStart[step.id] = start
                dragging[step.id] = CGPoint(x: max(0, start.x + g.translation.width), y: max(0, start.y + g.translation.height))
                sel = .step(step.id)
            }
            .onEnded { _ in endGroupDrag() })
        .onTapGesture { choose("s:" + step.id, as: .step(step.id)) }
        .overlay(alignment: .top) {
            VStack(spacing: 2) {
                Text(step.title).font(.system(size: 14, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                Text(subtitle(step)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                if !step.about.isEmpty {
                    Text(step.about).font(.system(size: 12).italic()).foregroundStyle(.tertiary).lineLimit(3).multilineTextAlignment(.center)
                }
            }
            .frame(width: 190)
            .offset(y: box.height + 8)
            .allowsHitTesting(false)
        }
        .offset(x: box.minX, y: box.minY)
    }

    /// A connection dot on the middle of a side.
    private func sideDot(_ step: FlowStep, _ side: FlowSide) -> some View {
        let r = Self.tile
        let p: CGPoint
        switch side {
        case .left: p = CGPoint(x: 0, y: r.height / 2)
        case .right: p = CGPoint(x: r.width, y: r.height / 2)
        case .top: p = CGPoint(x: r.width / 2, y: 0)
        case .bottom: p = CGPoint(x: r.width / 2, y: r.height)
        }
        return Circle().fill(Theme.card).overlay(Circle().stroke(Color.secondary, lineWidth: 1.6))
            .frame(width: 14, height: 14).contentShape(Circle().inset(by: -7))
            .position(p)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { g in if !running { connecting = (step.id, branches(step) ? .pass : .always, side, g.location) } }
                .onEnded { g in finishConnection(from: step.id, condition: branches(step) ? .pass : .always, side: side, at: g.location) })
            .help("Drag to another step to connect")
    }

    private func outputDot(_ step: FlowStep, _ side: FlowSide, _ condition: EdgeCondition, y: CGFloat, label: String) -> some View {
        ZStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                .position(x: Self.tile.width + 24, y: y - 11)
            Circle().fill(Theme.card).overlay(Circle().stroke(condition == .fail ? Color.red.opacity(0.8) : Color.secondary, lineWidth: 1.6))
                .frame(width: 14, height: 14).contentShape(Circle().inset(by: -7))
                .position(x: Self.tile.width, y: y)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                    .onChanged { g in if !running { connecting = (step.id, condition, side, g.location) } }
                    .onEnded { g in finishConnection(from: step.id, condition: condition, side: side, at: g.location) })
                .help(condition == .fail ? "Drag to where the work goes when this fails" : "Drag to the next step")
        }
        .frame(width: Self.tile.width, height: Self.tile.height, alignment: .topLeading)
    }

    private func finishConnection(from id: String, condition: EdgeCondition, side: FlowSide, at point: CGPoint) {
        connecting = nil
        guard !running else { return }
        guard let target = project.steps.first(where: { $0.id != id && rect($0).insetBy(dx: -16, dy: -16).contains(point) }) else { return }
        let toSide = nearestSide(target, to: point)
        if model.connect(project.id, from: id, to: target.id, condition: condition, fromSide: side, toSide: toSide) {
            sel = .edge("\(id)->\(target.id)")
        } else {
            flashRejected()
        }
    }

    private func subtitle(_ step: FlowStep) -> String {
        if step.kind == .approval { return "you decide" }
        let names = step.agentIDs.compactMap { id in model.projectAgents(project).first(where: { $0.id == id })?.firstName }
        if let first = names.first { return names.count > 1 ? "\(first) +\(names.count - 1)" : first }
        if let role = step.role { return role.title }
        return "pick who does it"
    }

    private func borderColor(_ status: StepStatus) -> Color {
        switch status {
        case .running: return .blue
        case .waiting: return .orange
        case .done: return Theme.onlineGreen
        case .failed, .rejected: return .red
        case .skipped: return Color.secondary.opacity(0.4)
        case .pending: return Theme.stroke
        }
    }

    @ViewBuilder private func statusBadge(_ status: StepStatus) -> some View {
        switch status {
        case .pending: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "pause.circle.fill").font(.system(size: 16)).foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.onlineGreen)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).foregroundStyle(.red)
        case .rejected: Image(systemName: "hand.raised.slash.fill").font(.system(size: 15)).foregroundStyle(.red)
        case .skipped: Image(systemName: "arrow.turn.down.right").font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    // MARK: Zoom and run

    private func zoomControls(in size: CGSize) -> some View {
        HStack(spacing: 6) {
            Button { fit(in: size) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Fit to view")
            Button { zoom = min(2, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            Button { zoom = max(0.3, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
        }
        .buttonStyle(.plain).font(.system(size: 16))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
    }

    private func fit(in size: CGSize) {
        let maxX = project.steps.map { rect($0).maxX }.max() ?? 1
        let maxY = project.steps.map { rect($0).maxY }.max() ?? 1
        zoom = max(0.3, min(1.4, min(size.width / (maxX + 100), size.height / (maxY + 130))))
    }

    private var executeButton: some View {
        let waiting = project.steps.contains { $0.status == .waiting }
        let blocked = !model.missingTeams(for: project).isEmpty || project.steps.isEmpty
        return Button {
            if running { model.cancelProject(project.id) }
            else if project.isFinished { model.startProject(project.id, all: true) }
            else { model.startProject(project.id) }
        } label: {
            Label(running ? "Stop" : project.isFinished ? "Run again" : waiting ? "Continue (waiting for approval)" : "Execute process",
                  systemImage: running ? "stop.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Capsule().fill(Color(white: 0.12)))
        }
        .buttonStyle(.plain)
        .opacity(blocked && !running ? 0.4 : 1)
        .disabled(blocked && !running)
        .help(blocked ? "Some steps have no agent." : "Run the process")
    }
}

private struct MultiInspector: View {
    let count: Int
    let steps: Int
    let running: Bool
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onAlignLeft: () -> Void
    let onAlignTop: () -> Void
    let onClear: () -> Void

    var body: some View {
        InspectorCard {
            Label("\(count) selected", systemImage: "rectangle.dashed").font(.title3.weight(.semibold))
            Text("\(steps) step\(steps == 1 ? "" : "s") and \(count - steps) note\((count - steps) == 1 ? "" : "s"). Drag any of them to move them all.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { onAlignLeft() } label: { Label("Align left", systemImage: "align.horizontal.left") }
                Button { onAlignTop() } label: { Label("Align top", systemImage: "align.vertical.top") }
            }
            Button { onDuplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.disabled(running)
            Button(role: .destructive) { onDelete() } label: { Label("Delete all selected", systemImage: "trash") }
            Button("Clear selection") { onClear() }
            Text("Shift-click adds or removes one item. Drag a region on the empty canvas to select what it covers.").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

enum NoteStyle {
    static func fill(_ c: FlowNote.Color) -> Color {
        switch c {
        case .yellow: return Color(red: 1.0, green: 0.93, blue: 0.62)
        case .blue: return Color(red: 0.78, green: 0.89, blue: 1.0)
        case .green: return Color(red: 0.80, green: 0.94, blue: 0.80)
        case .pink: return Color(red: 1.0, green: 0.82, blue: 0.86)
        }
    }
}

extension StepKind {
    /// Steps that can pass or fail get two outputs.
    var branches: Bool { [.review, .test, .task, .provision, .deploy].contains(self) }
}

private struct InspectorCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 10) { content }.padding(12) }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
    }
}

private struct InspectorHelp: View {
    var body: some View {
        InspectorCard {
            Label("Process editor", systemImage: "point.3.connected.trianglepath.dotted").font(.title3.weight(.semibold))
            Group {
                Text("**Add** a step, a human approval or a note from the bar above, or press + at an open output.")
                Text("**Move** a tile by dragging it. **Connect** by dragging from a dot on any side of a tile (top, bottom, left or right) to another tile.")
                Text("**Click a tile** or a note and change everything about it here: name, description, who does it, connections. Nothing is edited on the canvas itself.")
                Text("**Click the dot on an arrow** to select it. Here you can label it, choose the sides it leaves from and enters at, or put a step in the middle. Drag the green handles on its ends to move them to another side or step. Delete removes it.")
                Text("Review, test and deploy steps have a pass and a fail output. Connect fail back to an earlier step to make a rework loop (at most \(ProjectFlow.maxLoops) rounds).")
                Text("Press \u{232B} to delete what is selected.")
            }.font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct NoteInspector: View {
    @ObservedObject var model: AppModel
    let projectID: String
    let note: FlowNote
    let onRemove: () -> Void

    var body: some View {
        InspectorCard {
            HStack {
                Label("Note", systemImage: "note.text").font(.title3.weight(.semibold))
                Spacer()
                Button(role: .destructive) { model.removeNote(projectID, note.id); onRemove() } label: { Image(systemName: "trash") }.help("Delete this note")
            }
            TextEditor(text: Binding(get: { note.text }, set: { v in model.editNote(projectID, note.id) { $0.text = v } }))
                .font(.body).frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
            HStack(spacing: 8) {
                ForEach(FlowNote.Color.allCases, id: \.self) { c in
                    Circle().fill(NoteStyle.fill(c)).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(note.color == c ? Theme.green : Color.black.opacity(0.2), lineWidth: note.color == c ? 2.5 : 1))
                        .onTapGesture { model.editNote(projectID, note.id) { $0.color = c } }
                }
            }
            Text("Notes are only for people. Agents never read them. Drag the corner to resize.").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct EdgeInspector: View {
    @ObservedObject var model: AppModel
    let project: Project
    let edge: FlowEdge
    let select: (ProcessEditorView.Selection?) -> Void

    private var running: Bool { model.isRunning(project.id) }

    var body: some View {
        let from = project.step(edge.from)?.title ?? edge.from
        let to = project.step(edge.to)?.title ?? edge.to
        InspectorCard {
            HStack {
                Label(edge.loop ? "Rework loop" : "Connection", systemImage: edge.loop ? "arrow.triangle.2.circlepath" : "arrow.right").font(.title3.weight(.semibold))
                Spacer()
                Button(role: .destructive) { model.setEdge(project.id, edge.id, condition: nil); select(nil) } label: { Image(systemName: "trash") }
                    .help("Remove this connection").disabled(running)
            }
            Text("\(from)  \u{2192}  \(to)").font(.body)
            TextField("Text on the arrow (optional)", text: Binding(get: { edge.label }, set: { model.setEdgeLabel(project.id, edge.id, $0) }))
                .textFieldStyle(.roundedBorder)
            Picker("Leaves from", selection: Binding(get: { edge.fromSide }, set: { model.reconnect(project.id, edge.id, fromSide: $0, toSide: edge.toSide) })) {
                Text("Automatic").tag(FlowSide?.none)
                ForEach(FlowSide.allCases, id: \.self) { Text($0.label).tag(FlowSide?.some($0)) }
            }.disabled(running)
            Picker("Enters at", selection: Binding(get: { edge.toSide }, set: { model.reconnect(project.id, edge.id, fromSide: edge.fromSide, toSide: $0) })) {
                Text("Automatic").tag(FlowSide?.none)
                ForEach(FlowSide.allCases, id: \.self) { Text($0.label).tag(FlowSide?.some($0)) }
            }.disabled(running)
            if edge.loop {
                Text("Followed when \(from) fails. The work goes back to \(to), at most \(ProjectFlow.maxLoops) times (used: \(edge.rounds)).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Followed", selection: Binding(get: { edge.condition }, set: { model.setEdge(project.id, edge.id, condition: $0) })) {
                    ForEach(EdgeCondition.allCases, id: \.self) { Text($0.label).tag($0) }
                }.disabled(running)
                Divider()
                Text("Put a step on this connection").font(.callout.weight(.semibold))
                Button { if let id = model.insertStep(project.id, kind: .approval, on: edge.id) { select(.step(id)) } } label: {
                    Label("Add a human approval here", systemImage: "hand.raised.fill")
                }.disabled(running)
                Menu {
                    ForEach(StepKind.palette.filter { $0 != .approval }, id: \.self) { k in
                        Button { if let id = model.insertStep(project.id, kind: k, on: edge.id) { select(.step(id)) } } label: { Label(k.label, systemImage: k.icon) }
                    }
                } label: { Label("Add another step here", systemImage: "plus.circle") }.disabled(running)
            }
            if running { Text("Editing is locked while the process runs.").font(.caption).foregroundStyle(.orange) }
        }
    }
}

/// Settings of the selected step.
private struct StepInspector: View {
    @ObservedObject var model: AppModel
    let project: Project
    let step: FlowStep
    let select: (ProcessEditorView.Selection?) -> Void

    private var running: Bool { model.isRunning(project.id) }

    private func edit(_ change: @escaping (inout FlowStep) -> Void) { model.editStep(project.id, step.id, change) }

    private func title(_ id: String) -> String { project.step(id)?.title ?? id }

    var body: some View {
        InspectorCard {
            HStack {
                Image(systemName: step.kind.icon).foregroundStyle(step.kind == .approval ? .orange : Theme.green)
                Text(step.kind.label).font(.title3.weight(.semibold))
                Spacer()
                Button { if let n = model.duplicateStep(project.id, step.id) { select(.step(n)) } } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate this step").disabled(running)
                Button(role: .destructive) { model.removeStep(project.id, step.id); select(nil) } label: { Image(systemName: "trash") }
                    .help("Remove this step").disabled(running)
            }
            TextField("Name", text: Binding(get: { step.name }, set: { v in edit { $0.name = v } }), prompt: Text(FlowStep(kind: step.kind, env: step.env).title))
                .textFieldStyle(.roundedBorder)

            Text(step.kind == .approval ? "What should you check? (shown when it asks)" : "Description").font(.callout.weight(.semibold))
            TextEditor(text: Binding(get: { step.about }, set: { v in edit { $0.about = v } }))
                .font(.body).frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))

            if step.kind.usesEnvironment {
                Picker("Environment", selection: Binding(get: { step.env ?? "" }, set: { v in edit { $0.env = v } })) {
                    ForEach(project.environments.map { $0.name }, id: \.self) { Text($0).tag($0) }
                }
            }
            if step.kind == .approval {
                Text("The process waits here until you approve in the Progress tab.").font(.callout).foregroundStyle(.secondary)
            } else {
                agents
            }

            if step.kind != .approval {
                Text(step.kind == .task ? "What should it do?" : "Additional instructions").font(.callout.weight(.semibold))
                TextEditor(text: Binding(get: { step.extra }, set: { v in edit { $0.extra = v } }))
                    .font(.body).frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
                Text("Output").font(.callout.weight(.semibold))
                if step.kind == .task {
                    TextField("Result file", text: Binding(get: { step.outputName }, set: { v in edit { $0.outputName = v } }),
                              prompt: Text("reports/\(step.id).md")).textFieldStyle(.roundedBorder)
                } else if let f = step.outputFile {
                    Text("Writes \(f)").font(.callout).foregroundStyle(.secondary)
                }
                if step.kind.branches {
                    Text("Ends with a Verdict line. Fail sends the work along the fail output.").font(.caption).foregroundStyle(.tertiary)
                }
            }

            Divider()
            connections

            if !step.error.isEmpty { Text(step.error).font(.callout).foregroundStyle(.red) }
            if !step.summary.isEmpty { Text(step.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if running { Text("Editing is locked while the process runs.").font(.caption).foregroundStyle(.orange) }
        }
    }

    /// Who does the step. Several agents work one after the other; each improves on the previous one's work.
    @ViewBuilder private var agents: some View {
        let all = model.projectAgents(project)
        let chosen = step.agentIDs.compactMap { id in all.first { $0.id == id } }
        let available = all.filter { p in !step.agentIDs.contains(p.id) }
        let wanted = step.role?.title
        let grouped = Dictionary(grouping: available) { ProjectFlow.capability(of: $0, in: model.company) }
        let order = (wanted.map { [$0] } ?? []) + grouped.keys.filter { $0 != wanted }.sorted()
        Text("Agents").font(.callout.weight(.semibold))
        if chosen.isEmpty {
            let fallback = ProjectFlow.agent(for: step, in: model.company)
            Label(fallback.map { "Default: \($0.person.name). Add an agent to choose yourself." } ?? "No agent yet. Add one.",
                  systemImage: "person.crop.circle").font(.callout).foregroundStyle(fallback == nil ? Color.orange : Color.secondary)
        }
        ForEach(Array(chosen.enumerated()), id: \.element.id) { n, person in
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.olive)
                VStack(alignment: .leading, spacing: 0) {
                    Text(person.name).font(.callout)
                    Text((n == 0 ? person.role : "\(person.role) \u{00B7} then improves on the above") + " \u{00B7} \(usageLabel(person.id))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let team = model.company.teams.first(where: { $0.members.contains { $0.id == person.id } }) {
                    Button { model.companySheet = .editAgent(person, teamID: team.id) } label: { Image(systemName: "pencil.circle").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Edit this agent's settings")
                }
                Button { model.removeStepAgent(project.id, step.id, person.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).disabled(running).help("Remove this agent from the step")
            }
        }
        Menu {
            ForEach(order, id: \.self) { cap in
                if let people = grouped[cap] {
                    Section(cap) {
                        ForEach(people) { p in Button("\(p.name) \u{00B7} \(p.role) \u{00B7} \(usageLabel(p.id))") { model.addStepAgent(project.id, step.id, p.id) } }
                    }
                }
            }
            Divider()
            Button("New agent\u{2026}") {
                if let team = model.homeTeamID() { model.pendingStepAgent = (project.id, step.id); model.companySheet = .newAgent(teamID: team) }
            }
        } label: { Label("Add agent\u{2026}", systemImage: "person.crop.circle.badge.plus") }
            .menuStyle(.borderlessButton).fixedSize().disabled(running)
        if chosen.count > 1 { Text("They work one after the other, in this order.").font(.caption).foregroundStyle(.tertiary) }
    }

    private func usageLabel(_ id: String) -> String {
        let n = model.usage(of: id).count
        return n == 0 ? "not used yet" : n == 1 ? "in 1 project" : "in \(n) projects"
    }

    @ViewBuilder private var connections: some View {
        let incoming = project.edges.filter { $0.to == step.id }
        let outgoing = project.edges.filter { $0.from == step.id }
        let others = project.steps.filter { $0.id != step.id }
        Text("Connections").font(.callout.weight(.semibold))
        if incoming.isEmpty && outgoing.isEmpty { Text("None yet.").font(.callout).foregroundStyle(.tertiary) }
        ForEach(incoming) { e in
            connectionRow(e, text: "from \(title(e.from))")
        }
        ForEach(outgoing) { e in
            connectionRow(e, text: (e.loop ? "\u{21BB} back to " : (step.kind.branches ? "\(e.condition == .fail ? "fail" : e.condition == .pass ? "pass" : "always") \u{2192} " : "to ")) + title(e.to))
        }
        Menu {
            if step.kind.branches {
                Menu("On pass, go to") { ForEach(others) { t in Button(t.title) { model.connect(project.id, from: step.id, to: t.id, condition: .pass) } } }
                Menu("On fail, go to") { ForEach(others) { t in Button(t.title) { model.connect(project.id, from: step.id, to: t.id, condition: .fail) } } }
            } else {
                ForEach(others) { t in Button(t.title) { model.connect(project.id, from: step.id, to: t.id) } }
            }
        } label: { Label("Connect to\u{2026}", systemImage: "arrow.right.circle") }
            .menuStyle(.borderlessButton).fixedSize().disabled(running || others.isEmpty)
    }

    private func connectionRow(_ e: FlowEdge, text: String) -> some View {
        HStack(spacing: 6) {
            Button { select(.edge(e.id)) } label: { Text(text).font(.callout).lineLimit(1) }.buttonStyle(.plain)
            Spacer()
            Button { model.setEdge(project.id, e.id, condition: nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).disabled(running).help("Remove this connection")
        }
    }
}

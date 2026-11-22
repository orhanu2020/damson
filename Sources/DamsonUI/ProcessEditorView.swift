import SwiftUI
import DamsonCore

/// The project's process as a canvas of steps connected by lines (like n8n): drag steps around, drag from the dot on a
/// step's right side to another step to connect them, click the label on a line to change when it is followed.
struct ProcessEditorView: View {
    @ObservedObject var model: AppModel
    let project: Project

    @State private var selected: String?
    @State private var dragStart: [String: CGPoint] = [:]
    @State private var dragging: [String: CGPoint] = [:]
    @State private var connecting: (from: String, to: CGPoint)?
    @State private var confirmReset = false
    @State private var rejectedConnection = false

    static let nodeSize = CGSize(width: 184, height: 62)

    private var running: Bool { model.isRunning(project.id) }

    private func origin(_ step: FlowStep) -> CGPoint { dragging[step.id] ?? CGPoint(x: step.x, y: step.y) }

    private func rect(_ step: FlowStep) -> CGRect { CGRect(origin: origin(step), size: Self.nodeSize) }

    private func outPort(_ step: FlowStep) -> CGPoint { CGPoint(x: rect(step).maxX, y: rect(step).midY) }
    private func inPort(_ step: FlowStep) -> CGPoint { CGPoint(x: rect(step).minX, y: rect(step).midY) }

    private var contentSize: CGSize {
        let maxX = project.steps.map { rect($0).maxX }.max() ?? 0
        let maxY = project.steps.map { rect($0).maxY }.max() ?? 0
        return CGSize(width: max(860, maxX + 240), height: max(420, maxY + 160))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            HStack(alignment: .top, spacing: 12) {
                canvas
                if let step = project.steps.first(where: { $0.id == selected }) {
                    StepInspector(model: model, project: project, step: step, onRemove: { selected = nil })
                        .frame(width: 270)
                }
            }
        }
        .confirmationDialog("Replace this process with the standard delivery process?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Replace and clear progress", role: .destructive) { selected = nil; model.resetProcess(project.id) }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(StepKind.palette, id: \.self) { kind in
                    Button { add(kind) } label: { Label(kind.label, systemImage: kind.icon) }
                }
            } label: { Label("Add step", systemImage: "plus.circle.fill") }
                .menuStyle(.borderlessButton).fixedSize().disabled(running)
            Button { confirmReset = true } label: { Label("Standard process", systemImage: "arrow.counterclockwise") }
                .controlSize(.small).disabled(running)
            Spacer()
            legend(.secondary, "always")
            legend(.green, "on pass")
            legend(.red, "on fail")
        }
        .overlay(alignment: .bottomLeading) {
            if rejectedConnection {
                Text("That connection is not allowed (a step cannot lead back to itself or to an earlier step).")
                    .font(.caption2).foregroundStyle(.orange).offset(y: 16)
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 16, height: 2.5)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func add(_ kind: StepKind) {
        // Below the lowest step, so a new step never lands on top of another one.
        let y = (project.steps.map { $0.y }.max() ?? 0) + ProjectFlow.rowHeight
        if let id = model.addStep(project.id, kind: kind, at: CGPoint(x: 40, y: y)) { selected = id }
    }

    // MARK: Canvas

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in project.edges {
                        guard let a = project.step(edge.from), let b = project.step(edge.to) else { continue }
                        draw(context, from: outPort(a), to: inPort(b), color: color(edge.condition), dashed: false)
                    }
                    if let c = connecting, let a = project.step(c.from) {
                        draw(context, from: outPort(a), to: c.to, color: Theme.green, dashed: true)
                    }
                }
                .frame(width: contentSize.width, height: contentSize.height)
                .allowsHitTesting(false)

                ForEach(project.edges) { edge in
                    if let a = project.step(edge.from), let b = project.step(edge.to) {
                        edgeHandle(edge, from: outPort(a), to: inPort(b))
                    }
                }
                ForEach(project.steps) { step in node(step) }
            }
            .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
            .coordinateSpace(name: "canvas")
            .contentShape(Rectangle())
            .onTapGesture { selected = nil }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
        .frame(minHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func color(_ condition: EdgeCondition) -> Color {
        switch condition {
        case .always: return Color.secondary
        case .pass: return .green
        case .fail: return .red
        }
    }

    private func draw(_ context: GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color, dashed: Bool) {
        let dx = max(50, abs(b.x - a.x) / 2)
        var path = Path()
        path.move(to: a)
        path.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        context.stroke(path, with: .color(color.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: dashed ? [6, 4] : []))
        var arrow = Path()
        arrow.move(to: b)
        arrow.addLine(to: CGPoint(x: b.x - 9, y: b.y - 5))
        arrow.addLine(to: CGPoint(x: b.x - 9, y: b.y + 5))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color.opacity(0.85)))
    }

    /// The label in the middle of a line: tells when it is followed and lets the user change or remove it.
    private func edgeHandle(_ edge: FlowEdge, from a: CGPoint, to b: CGPoint) -> some View {
        Menu {
            ForEach(EdgeCondition.allCases, id: \.self) { c in
                Button { model.setEdge(project.id, edge.id, condition: c) } label: {
                    if c == edge.condition { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                }
            }
            Divider()
            Button("Remove connection", role: .destructive) { model.setEdge(project.id, edge.id, condition: nil) }
        } label: {
            Text(edge.condition == .always ? "\u{2022}" : edge.condition.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color(edge.condition))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().stroke(color(edge.condition).opacity(0.7), lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(running)
        .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    // MARK: Steps

    private func node(_ step: FlowStep) -> some View {
        let box = rect(step)
        let isSelected = selected == step.id
        return ZStack {
            card(step, selected: isSelected)
                .frame(width: box.width, height: box.height)
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
                    .onChanged { g in
                        let start = dragStart[step.id] ?? CGPoint(x: step.x, y: step.y)
                        dragStart[step.id] = start
                        dragging[step.id] = CGPoint(x: max(0, start.x + g.translation.width), y: max(0, start.y + g.translation.height))
                    }
                    .onEnded { _ in
                        if let p = dragging[step.id] { model.moveStep(project.id, step.id, to: p) }
                        dragging[step.id] = nil
                        dragStart[step.id] = nil
                    })
                .onTapGesture { selected = step.id }
            // Input dot (left) and output dot (right, drag from it to connect).
            Circle().fill(Theme.card).overlay(Circle().stroke(Color.secondary, lineWidth: 2))
                .frame(width: 12, height: 12).position(x: 0, y: box.height / 2)
            Circle().fill(Theme.green).overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                .frame(width: 14, height: 14).contentShape(Circle().inset(by: -6))
                .position(x: box.width, y: box.height / 2)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                    .onChanged { g in if !running { connecting = (step.id, g.location) } }
                    .onEnded { g in finishConnection(from: step.id, at: g.location) })
                .help("Drag to another step to connect")
        }
        .frame(width: box.width, height: box.height)
        .offset(x: box.minX, y: box.minY)
    }

    private func finishConnection(from id: String, at point: CGPoint) {
        connecting = nil
        guard !running else { return }
        guard let target = project.steps.first(where: { $0.id != id && rect($0).insetBy(dx: -10, dy: -10).contains(point) }) else { return }
        if !model.connect(project.id, from: id, to: target.id) {
            rejectedConnection = true
            Task { try? await Task.sleep(nanoseconds: 3_500_000_000); rejectedConnection = false }
        }
    }

    private func card(_ step: FlowStep, selected: Bool) -> some View {
        let tint: Color = step.kind == .approval ? .orange : Theme.green
        return HStack(spacing: 8) {
            Image(systemName: step.kind.icon).font(.system(size: 15)).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(subtitle(step)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            statusBadge(step.status)
        }
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected ? Theme.green : borderColor(step.status), lineWidth: selected ? 2.5 : 1.5))
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
    }

    private func subtitle(_ step: FlowStep) -> String {
        if step.kind == .approval { return "You decide" }
        if let id = step.agentID, let person = model.projectAgents(project).first(where: { $0.id == id }) { return person.name }
        if let role = step.role { return role.title }
        return "Pick who does it"
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
        case .running: ProgressView().controlSize(.mini)
        case .waiting: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.onlineGreen)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .rejected: Image(systemName: "hand.raised.slash.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
        }
    }
}

/// Settings of the selected step.
private struct StepInspector: View {
    @ObservedObject var model: AppModel
    let project: Project
    let step: FlowStep
    let onRemove: () -> Void

    private var running: Bool { model.isRunning(project.id) }

    private func edit(_ change: @escaping (inout FlowStep) -> Void) { model.editStep(project.id, step.id, change) }

    private var assignee: Binding<String> {
        Binding(get: {
            if let id = step.agentID { return "agent:\(id)" }
            return "role:\(step.customRole?.rawValue ?? "")"
        }, set: { value in
            edit { s in
                if value.hasPrefix("agent:") { s.agentID = String(value.dropFirst(6)); s.customRole = nil }
                else { s.agentID = nil; s.customRole = TeamRole(rawValue: String(value.dropFirst(5))) }
            }
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: step.kind.icon).foregroundStyle(step.kind == .approval ? .orange : Theme.green)
                    Text(step.kind.label).font(.headline)
                    Spacer()
                    Button(role: .destructive) { model.removeStep(project.id, step.id); onRemove() } label: { Image(systemName: "trash") }
                        .help("Remove this step").disabled(running)
                }
                TextField("Name", text: Binding(get: { step.name }, set: { v in edit { $0.name = v } }), prompt: Text(FlowStep(kind: step.kind, env: step.env).title))
                    .textFieldStyle(.roundedBorder)

                if step.kind.usesEnvironment {
                    Picker("Environment", selection: Binding(get: { step.env ?? "" }, set: { v in edit { $0.env = v } })) {
                        ForEach(project.environments.map { $0.name }, id: \.self) { Text($0).tag($0) }
                    }
                }
                if step.kind == .task {
                    Picker("Done by", selection: assignee) {
                        Text("Choose\u{2026}").tag("role:")
                        Section("Team") { ForEach(TeamRole.allCases) { Text($0.title).tag("role:\($0.rawValue)") } }
                        Section("Agent") { ForEach(model.projectAgents(project)) { Text($0.name).tag("agent:\($0.id)") } }
                    }
                    TextField("Result file", text: Binding(get: { step.outputName }, set: { v in edit { $0.outputName = v } }),
                              prompt: Text("reports/\(step.id).md")).textFieldStyle(.roundedBorder)
                } else if step.kind != .approval {
                    Label("\(step.role?.title ?? "") team", systemImage: "person.2.fill").font(.caption).foregroundStyle(.secondary)
                    if let f = step.outputFile { Text("Writes \(f)").font(.caption2).foregroundStyle(.tertiary) }
                } else {
                    Text("The process waits here until you approve in the Progress tab.").font(.caption).foregroundStyle(.secondary)
                }

                if step.kind != .approval {
                    Text(step.kind == .task ? "What should it do?" : "Additional instructions").font(.caption.weight(.semibold))
                    TextEditor(text: Binding(get: { step.extra }, set: { v in edit { $0.extra = v } }))
                        .font(.callout).frame(height: 130)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
                }

                let incoming = project.edges.filter { $0.to == step.id }
                let outgoing = project.edges.filter { $0.from == step.id }
                Text("\(incoming.count) in \u{00B7} \(outgoing.count) out").font(.caption2).foregroundStyle(.tertiary)

                if !step.error.isEmpty { Text(step.error).font(.caption).foregroundStyle(.red) }
                if !step.summary.isEmpty { Text(step.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if running { Text("Editing is locked while the process runs.").font(.caption2).foregroundStyle(.orange) }
            }
            .padding(12)
        }
        .disabled(false)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
    }
}

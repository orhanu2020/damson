import SwiftUI
import DamsonCore

// MARK: - Layout (design coordinates; the office grows and shrinks with the teams)

/// Where everything sits on the floor: one room per capability (business analysis, design, development, test,
/// deployment, platform), three rooms per row, with a corridor between the columns. Everyone stays in their own room.
struct OfficeLayout {
    struct RoomSlot: Identifiable {
        let team: Team
        let rect: CGRect
        let tint: Color
        /// The column (0...2). Corridor i lies between column i and i+1.
        let col: Int
        /// The walls that have a door: +1 the right wall, -1 the left wall.
        let sides: [CGFloat]
        var id: String { team.id }

        var doorY: CGFloat { rect.maxY - 60 }
        func doorX(_ side: CGFloat) -> CGFloat { side > 0 ? rect.maxX : rect.minX }
        func insideX(_ side: CGFloat) -> CGFloat { side > 0 ? rect.maxX - 14 : rect.minX + 14 }
        func corridor(_ side: CGFloat) -> Int { side > 0 ? col : col - 1 }
        func side(toward corridor: Int) -> CGFloat? { sides.first { self.corridor($0) == corridor } }
        /// The side used to go out for a drink or a chat when nothing else is asked.
        var mainSide: CGFloat { sides.first ?? 1 }
        /// The water and coffee corner along the bottom wall.
        var counterX: CGFloat { rect.maxX - 72 }
        var coffeeSpot: CGPoint { CGPoint(x: counterX - 25, y: rect.maxY - 38) }
        var waterSpot: CGPoint { CGPoint(x: counterX + 25, y: rect.maxY - 38) }
    }

    struct Desk: Identifiable {
        let id: String
        let center: CGPoint
    }

    struct Seat: Identifiable {
        let person: Person
        let tint: Color
        var id: String { person.id }
    }

    static let corridorWidth: CGFloat = 64

    var size = CGSize(width: 640, height: 420)
    var corridors: [CGRect] = []
    var rooms: [RoomSlot] = []
    var desks: [Desk] = []
    var seats: [Seat] = []
    var homes: [String: CGPoint] = [:]
    var roomIndex: [String: Int] = [:]

    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.55, blue: 0.40),
        Color(red: 0.30, green: 0.45, blue: 0.75),
        Color(red: 0.80, green: 0.50, blue: 0.25),
        Color(red: 0.62, green: 0.40, blue: 0.70),
        Color(red: 0.75, green: 0.35, blue: 0.40),
        Color(red: 0.25, green: 0.60, blue: 0.65),
    ]

    /// Room size from the number of people: up to 3 desks per row, as many rows as needed.
    private static func roomSize(members n: Int) -> CGSize {
        let cols = min(max(n, 1), 3)
        let rows = max(1, (n + 2) / 3)
        return CGSize(width: max(240, 124 + CGFloat(cols - 1) * 121), height: 64 + 78 * CGFloat(rows) + 34)
    }

    /// The rooms: the standard capabilities in order (always shown), then any other capability somebody has.
    static func rooms(of company: Company) -> [Team] {
        var names = ProjectFlow.capabilities
        var buckets: [String: [Person]] = [:]
        for person in company.allPeople {
            let c = ProjectFlow.capability(of: person, in: company)
            let name = names.first { $0.caseInsensitiveCompare(c) == .orderedSame } ?? c
            if !names.contains(name) { names.append(name) }
            buckets[name, default: []].append(person)
        }
        return names.map { Team(id: "cap:" + $0, name: $0, members: buckets[$0] ?? []) }
    }

    init(company: Company) {
        let margin: CGFloat = 16
        let teams = Self.rooms(of: company)
        let sizes = teams.map { Self.roomSize(members: $0.members.count) }
        let perRow = 3
        let cols = min(perRow, max(teams.count, 1))
        let colW = max(250, sizes.map { $0.width }.max() ?? 0)
        let cw = Self.corridorWidth
        let rowCount = (teams.count + perRow - 1) / perRow
        var rowY: [CGFloat] = [], rowH: [CGFloat] = []
        var y = margin
        for r in 0..<rowCount {
            let h = sizes[(r * perRow)..<min(teams.count, (r + 1) * perRow)].map { $0.height }.max() ?? 0
            rowY.append(y); rowH.append(h); y += h + margin
        }
        size = CGSize(width: margin * 2 + CGFloat(cols) * colW + CGFloat(cols - 1) * cw, height: max(y, 200))
        corridors = (0..<max(cols - 1, 0)).map { i in
            CGRect(x: margin + CGFloat(i + 1) * colW + CGFloat(i) * cw, y: margin, width: cw, height: size.height - 2 * margin)
        }

        for (index, team) in teams.enumerated() {
            let col = index % perRow, row = index / perRow
            let rect = CGRect(x: margin + CGFloat(col) * (colW + cw), y: rowY[row], width: colW, height: rowH[row])
            let tint = Self.palette[index % Self.palette.count]
            var sides: [CGFloat] = []
            if col > 0 { sides.append(-1) }
            if col < cols - 1 { sides.append(1) }
            rooms.append(RoomSlot(team: team, rect: rect, tint: tint, col: col, sides: sides))
            let n = min(max(team.members.count, 1), 3)
            let firstX = rect.midX - CGFloat(n - 1) * 121 / 2
            for (j, person) in team.members.enumerated() {
                let px = firstX + CGFloat(j % 3) * 121
                let deskY = rect.minY + 62 + CGFloat(j / 3) * 78
                desks.append(Desk(id: person.id, center: CGPoint(x: px, y: deskY)))
                homes[person.id] = CGPoint(x: px, y: deskY + 34)
                roomIndex[person.id] = rooms.count - 1
                seats.append(Seat(person: person, tint: tint))
            }
        }
    }
}

// MARK: - Simulation: people stay in their room and walk between their teammates' tables

@MainActor
final class OfficeSim: ObservableObject {
    @Published var pos: [String: CGPoint] = [:]
    @Published var bubble: [String: String] = [:]
    @Published var walking: Set<String> = []
    @Published var facing: [String: CGFloat] = [:]

    /// People who are selected or working stay at their desks.
    var isAssigned: (String) -> Bool = { _ in false }

    private var layout = OfficeLayout(company: .sample)
    private var busy = Set<String>()
    private var loop: Task<Void, Never>?

    func configure(layout: OfficeLayout) {
        let old = self.layout.homes
        self.layout = layout
        for (id, home) in layout.homes where pos[id] == nil || old[id] != home { pos[id] = home }
        for id in pos.keys where layout.homes[id] == nil { pos[id] = nil; bubble[id] = nil; walking.remove(id) }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor in
            while !Task.isCancelled {
                let wait = UInt64.random(in: 2...4) * 1_000_000_000
                try? await Task.sleep(nanoseconds: wait)
                if Task.isCancelled { break }
                trigger()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        busy.removeAll()
        bubble.removeAll()
        walking.removeAll()
        for (id, home) in layout.homes { pos[id] = home }
    }

    /// A free person does something: visits a teammate's table, meets someone in the corridor, or gets water or coffee.
    private func trigger() {
        guard busy.count < 8 else { return }
        let free = layout.homes.keys.filter { !busy.contains($0) && !isAssigned($0) }
        guard let a = free.randomElement(), let room = layout.roomIndex[a] else { return }
        let roll = Int.random(in: 0..<100)
        if roll < 30 {
            drink(a)
        } else if roll < 65, let b = free.filter({ $0 != a }).randomElement(), meet(a, b) {
            return
        } else if let b = free.filter({ $0 != a && layout.roomIndex[$0] == room }).randomElement() {
            visit(a, b)
        } else {
            drink(a)
        }
    }

    /// Out of the chair, along the aisle to the wall on the given side.
    private func toWall(_ id: String, side: CGFloat) -> [CGPoint] {
        guard let h = layout.homes[id], let r = layout.roomIndex[id] else { return [] }
        let room = layout.rooms[r]
        let aisle = h.y + 20
        return [CGPoint(x: h.x, y: aisle), CGPoint(x: room.insideX(side), y: aisle)]
    }

    /// Two people meet in a corridor both rooms open onto and chat.
    private func meet(_ a: String, _ b: String) -> Bool {
        guard let ha = layout.homes[a], let hb = layout.homes[b],
              let ra = layout.roomIndex[a], let rb = layout.roomIndex[b] else { return false }
        let roomA = layout.rooms[ra], roomB = layout.rooms[rb]
        guard let c = roomA.sides.map({ roomA.corridor($0) }).first(where: { roomB.side(toward: $0) != nil }),
              let sa = roomA.side(toward: c), let sb = roomB.side(toward: c) else { return false }
        busy.insert(a)
        busy.insert(b)
        let cx = layout.corridors[c].midX
        let y = (roomA.doorY + roomB.doorY) / 2
        let pathA = toWall(a, side: sa) + [CGPoint(x: roomA.insideX(sa), y: roomA.doorY), CGPoint(x: cx, y: roomA.doorY), CGPoint(x: cx - 14, y: y)]
        let pathB = toWall(b, side: sb) + [CGPoint(x: roomB.insideX(sb), y: roomB.doorY), CGPoint(x: cx, y: roomB.doorY), CGPoint(x: cx + 14, y: y)]
        Task { @MainActor in
            async let va = walk(a, pathA, abortable: true)
            async let vb = walk(b, pathB, abortable: true)
            let (visitedA, visitedB) = await (va, vb)
            if visitedA.count == pathA.count && visitedB.count == pathB.count {
                bubble[a] = "\u{1F4AC}"
                bubble[b] = "\u{1F4AC}"
                try? await Task.sleep(nanoseconds: UInt64.random(in: 4...8) * 1_000_000_000)
                bubble[a] = nil
                bubble[b] = nil
            }
            async let ba: Void = goHome(a, via: [ha] + visitedA)
            async let bb: Void = goHome(b, via: [hb] + visitedB)
            _ = await (ba, bb)
            busy.remove(a)
            busy.remove(b)
        }
        return true
    }

    /// Walk to the water and coffee corner of the own room, take a drink, walk back.
    private func drink(_ a: String) {
        guard let ha = layout.homes[a], let r = layout.roomIndex[a] else { return }
        let room = layout.rooms[r]
        let coffee = Bool.random()
        let spot = coffee ? room.coffeeSpot : room.waterSpot
        let side = room.mainSide
        let path = toWall(a, side: side) + [CGPoint(x: room.insideX(side), y: spot.y), spot]
        busy.insert(a)
        Task { @MainActor in
            let visited = await walk(a, path, abortable: true)
            if visited.count == path.count {
                bubble[a] = coffee ? "\u{2615}" : "\u{1F4A7}"
                try? await Task.sleep(nanoseconds: UInt64.random(in: 3...5) * 1_000_000_000)
                bubble[a] = nil
            }
            await goHome(a, via: [ha] + visited)
            busy.remove(a)
        }
    }

    private func walk(_ id: String, _ points: [CGPoint], abortable: Bool) async -> [CGPoint] {
        var visited: [CGPoint] = []
        for p in points {
            if Task.isCancelled { break }
            if abortable && isAssigned(id) { break }
            let from = pos[id] ?? p
            if abs(p.x - from.x) > 1 { facing[id] = p.x > from.x ? 1 : -1 }
            walking.insert(id)
            let dist = hypot(Double(p.x - from.x), Double(p.y - from.y))
            let t = max(0.15, dist / 90.0)
            withAnimation(.linear(duration: t)) { pos[id] = p }
            try? await Task.sleep(nanoseconds: UInt64((t + 0.05) * 1_000_000_000))
            visited.append(p)
        }
        walking.remove(id)
        return visited
    }

    private func goHome(_ id: String, via visited: [CGPoint]) async {
        guard let home = layout.homes[id] else { return }
        let path = Array(visited.reversed().dropFirst()) + [home]
        _ = await walk(id, path, abortable: false)
    }

    private func visit(_ a: String, _ b: String) {
        guard let ha = layout.homes[a], let hb = layout.homes[b] else { return }
        busy.insert(a)
        busy.insert(b)
        Task { @MainActor in
            // Out of the chair into the aisle below the table row, along the aisle, then up beside the teammate's chair.
            let side: CGFloat = ha.x <= hb.x ? -30 : 30
            let aisleY = max(ha.y, hb.y) + 20
            let path = [CGPoint(x: ha.x, y: aisleY), CGPoint(x: hb.x + side, y: aisleY), CGPoint(x: hb.x + side, y: hb.y)]
            let visited = await walk(a, path, abortable: true)
            if visited.count == path.count {
                bubble[a] = "\u{1F4AC}"
                bubble[b] = "\u{1F4AC}"
                try? await Task.sleep(nanoseconds: UInt64.random(in: 3...6) * 1_000_000_000)
                bubble[a] = nil
                bubble[b] = nil
            }
            await goHome(a, via: [ha] + visited)
            busy.remove(a)
            busy.remove(b)
        }
    }
}

// MARK: - Views

struct FloorPlanView: View {
    @ObservedObject var model: AppModel
    @StateObject private var sim = OfficeSim()
    /// The width the office may use. It grows with the window up to `maxScale`, and never gets smaller than
    /// `minScale`: below that the page scrolls instead.
    var availableWidth: CGFloat = 900
    static let minScale: CGFloat = 0.9
    static let maxScale: CGFloat = 2.0

    var body: some View {
        let layout = OfficeLayout(company: model.company)
        let scale = min(max(availableWidth / layout.size.width, Self.minScale), Self.maxScale)
        office(layout)
            .frame(width: layout.size.width, height: layout.size.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
        .onAppear {
            sim.configure(layout: layout)
            sim.isAssigned = { [weak model] id in
                guard let model else { return false }
                return model.selectedPeople.contains(id) || model.personStatus[id] == .working
            }
            sim.start()
        }
        .onChange(of: model.company) { _, _ in sim.configure(layout: OfficeLayout(company: model.company)) }
        .onDisappear { sim.stop() }
    }

    private func office(_ layout: OfficeLayout) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22).fill(Theme.card).allowsHitTesting(false)
            ForEach(Array(layout.corridors.enumerated()), id: \.offset) { _, corridor in
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
                    .frame(width: corridor.width, height: corridor.height)
                    .position(x: corridor.midX, y: corridor.midY).allowsHitTesting(false)
            }
            ForEach(layout.rooms) { room in
                RoomView(model: model, room: room)
            }
            ForEach(layout.desks) { desk in
                DeskShape().position(desk.center).allowsHitTesting(false)
                Circle().fill(Color.primary.opacity(0.18)).frame(width: 20, height: 20)
                    .position(x: desk.center.x, y: desk.center.y + 30).allowsHitTesting(false)
            }
            ForEach(layout.seats) { seat in
                token(seat, layout)
            }
            RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.55), lineWidth: 6).allowsHitTesting(false)
        }
    }

    private func token(_ seat: OfficeLayout.Seat, _ layout: OfficeLayout) -> some View {
        let id = seat.person.id
        let point = sim.pos[id] ?? layout.homes[id] ?? .zero
        let reply = model.personStatus[id]
        let hasBubble = sim.bubble[id] != nil || reply != nil
        return PersonToken(person: seat.person,
                           tint: seat.tint,
                           selected: model.selectedPeople.contains(id),
                           emoji: sim.bubble[id],
                           status: reply,
                           walking: sim.walking.contains(id),
                           facing: sim.facing[id] ?? 1)
            .position(point)
            .zIndex(hasBubble ? 5 : 1)
            .onTapGesture { model.toggleSelection(id) }
    }
}

struct RoomView: View {
    @ObservedObject var model: AppModel
    let room: OfficeLayout.RoomSlot

    private var allSelected: Bool { room.team.members.allSatisfy { model.selectedPeople.contains($0.id) } }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(room.tint.opacity(0.09))
                .frame(width: room.rect.width, height: room.rect.height)
                .position(x: room.rect.midX, y: room.rect.midY)
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 12).stroke(room.tint.opacity(0.75), lineWidth: 4)
                .frame(width: room.rect.width, height: room.rect.height)
                .position(x: room.rect.midX, y: room.rect.midY)
                .allowsHitTesting(false)
            // Doors in the walls facing a corridor.
            ForEach(room.sides, id: \.self) { side in
                RoundedRectangle(cornerRadius: 2).fill(Theme.card)
                    .frame(width: 8, height: 36).position(x: room.doorX(side), y: room.doorY).allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 2).stroke(room.tint.opacity(0.75), lineWidth: 1.5)
                    .frame(width: 8, height: 36).position(x: room.doorX(side), y: room.doorY).allowsHitTesting(false)
            }
            // Water and coffee corner.
            RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.72, green: 0.55, blue: 0.38))
                .frame(width: 100, height: 14).position(x: room.counterX, y: room.rect.maxY - 10).allowsHitTesting(false)
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 12)).foregroundStyle(Color(red: 0.45, green: 0.28, blue: 0.15))
                .position(x: room.coffeeSpot.x, y: room.rect.maxY - 22).allowsHitTesting(false)
            Image(systemName: "drop.fill").font(.system(size: 12)).foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.85))
                .position(x: room.waterSpot.x, y: room.rect.maxY - 22).allowsHitTesting(false)
            HStack(spacing: 6) {
                Image(systemName: "door.left.hand.open").foregroundStyle(room.tint)
                Text(room.team.name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).layoutPriority(2)
                Text("\(room.team.members.count) \(room.team.members.count == 1 ? "agent" : "agents")").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 4)
                Button(allSelected ? "Deselect room" : "Select room") { model.setTeamSelected(room.team, !allSelected) }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(room.tint).fixedSize()
            }
            .frame(width: room.rect.width - 28)
            .position(x: room.rect.midX, y: room.rect.minY + 20)
        }
    }
}

struct DeskShape: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.72, green: 0.55, blue: 0.38)).frame(width: 80, height: 28)
            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.18)).frame(width: 26, height: 6).offset(y: -8)
            RoundedRectangle(cornerRadius: 1.5).fill(Color(white: 0.9)).frame(width: 14, height: 5).offset(x: -22, y: 5)
        }
    }
}

/// One person, drawn as a tiny figure (head, hair, shirt, arms, legs). Arms and legs swing while walking.
struct PersonToken: View {
    let person: Person
    let tint: Color
    let selected: Bool
    let emoji: String?
    let status: PersonStatus?
    let walking: Bool
    let facing: CGFloat

    private var hash: Int { person.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } }
    private var skin: Color {
        let tones = [Color(red: 0.96, green: 0.80, blue: 0.69), Color(red: 0.87, green: 0.68, blue: 0.52),
                     Color(red: 0.74, green: 0.54, blue: 0.38), Color(red: 0.55, green: 0.38, blue: 0.28)]
        return tones[hash % tones.count]
    }
    private var hair: Color {
        let tones = [Color(white: 0.12), Color(red: 0.35, green: 0.22, blue: 0.12), Color(red: 0.62, green: 0.42, blue: 0.20),
                     Color(red: 0.75, green: 0.70, blue: 0.65), Color(red: 0.50, green: 0.15, blue: 0.10)]
        return tones[(hash / 4) % tones.count]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !walking)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * 11
            figure(swing: walking ? sin(t) : 0, bob: walking ? -abs(sin(t)) * 1.6 : 0, t: t)
        }
        .frame(width: 30, height: 38)
        .overlay {
            Text(person.firstName).font(.system(size: 8, weight: .semibold)).foregroundStyle(.primary)
                .fixedSize().offset(y: 27)
        }
        .overlay(alignment: .bottom) { bubble.offset(y: -42) }
    }

    private func figure(swing: Double, bob: Double, t: Double) -> some View {
        ZStack {
            Ellipse().fill(Color.black.opacity(0.18)).frame(width: 18, height: 6).offset(y: 17)
            if selected {
                Ellipse().stroke(Theme.onlineGreen, lineWidth: 2.5).frame(width: 26, height: 9).offset(y: 17)
            }
            if walking { dust(t) }
            ZStack {
                limb(Color(white: 0.22), width: 4.5, height: 11, angle: swing * 28, x: -3, y: 11)
                limb(Color(white: 0.22), width: 4.5, height: 11, angle: -swing * 28, x: 3, y: 11)
                limb(tint.opacity(0.85), width: 3.5, height: 10, angle: -swing * 28, x: -8.5, y: 1)
                limb(tint.opacity(0.85), width: 3.5, height: 10, angle: swing * 28, x: 8.5, y: 1)
                RoundedRectangle(cornerRadius: 4).fill(tint).frame(width: 13, height: 15)
                Circle().fill(skin).frame(width: 11, height: 11).offset(y: -11)
                Circle().trim(from: 0.5, to: 1.0).fill(hair).frame(width: 11.5, height: 11.5).offset(y: -11)
                Circle().fill(Color(white: 0.1)).frame(width: 1.6, height: 1.6).offset(x: facing * 2.4, y: -10.5)
            }
            .offset(y: bob)
        }
    }

    private func limb(_ color: Color, width: CGFloat, height: CGFloat, angle: Double, x: CGFloat, y: CGFloat) -> some View {
        Capsule().fill(color).frame(width: width, height: height)
            .rotationEffect(.degrees(angle), anchor: .top)
            .offset(x: x, y: y)
    }

    private func dust(_ t: Double) -> some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                let phase = (t / 6 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                Circle()
                    .fill(Color.gray.opacity(0.4 * (1 - phase)))
                    .frame(width: 3 + 5 * phase, height: 3 + 5 * phase)
                    .offset(x: -facing * CGFloat(7 + 9 * phase), y: CGFloat(16 - 3 * phase))
            }
        }
    }

    @ViewBuilder private var bubble: some View {
        if case .replied(let text)? = status {
            speech(text)
        } else if case .working? = status {
            speech("\u{2699}\u{FE0F}\u{2026}")
        } else if let emoji {
            speech(emoji)
        }
    }

    private func speech(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 150)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

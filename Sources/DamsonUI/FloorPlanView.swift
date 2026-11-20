import SwiftUI
import DamsonCore

// MARK: - Layout (design coordinates; the office grows and shrinks with the teams)

/// Where everything sits on the floor. Team rooms are sized by how many people are in the team and packed into
/// a band above and a band below a central corridor. The meeting room and kitchen sit at the end of the lower band.
struct OfficeLayout {
    struct RoomSlot: Identifiable {
        let team: Team
        let rect: CGRect
        let door: CGPoint
        let corridor: CGPoint
        let tint: Color
        var id: String { team.id }
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

    var size = CGSize(width: 780, height: 540)
    var corridorY: CGFloat = 274
    var rooms: [RoomSlot] = []
    var desks: [Desk] = []
    var seats: [Seat] = []
    var homes: [String: CGPoint] = [:]
    var roomIndex: [String: Int] = [:]

    var kitchen = CGRect(x: 582, y: 310, width: 182, height: 214)
    var meeting = CGRect(x: 398, y: 310, width: 168, height: 214)
    var coffeeSpots: [CGPoint] { [CGPoint(x: kitchen.minX + 80, y: kitchen.minY + 66),
                                  CGPoint(x: kitchen.minX + 110, y: kitchen.minY + 66),
                                  CGPoint(x: kitchen.minX + 140, y: kitchen.minY + 66)] }
    var meetLeft: CGPoint { CGPoint(x: size.width / 2 - 18, y: corridorY + 10) }
    var meetRight: CGPoint { CGPoint(x: size.width / 2 + 18, y: corridorY + 10) }

    var kitchenDoor: CGPoint { CGPoint(x: kitchen.midX, y: kitchen.minY) }
    var kitchenCorridor: CGPoint { CGPoint(x: kitchen.midX, y: corridorY) }

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
        return CGSize(width: max(240, 124 + CGFloat(cols - 1) * 121), height: 64 + 78 * CGFloat(rows))
    }

    init(company: Company) {
        let margin: CGFloat = 16
        let serviceWidth = 168 + margin + 182   // meeting room + gap + kitchen

        // Pack teams into the top or bottom band, always into the one that is currently narrower.
        var top: [(Int, CGSize)] = []
        var bottom: [(Int, CGSize)] = []
        var topW: CGFloat = margin
        var bottomW: CGFloat = margin + serviceWidth + margin
        for (i, team) in company.teams.enumerated() {
            let sz = Self.roomSize(members: team.members.count)
            if topW <= bottomW {
                top.append((i, sz)); topW += sz.width + margin
            } else {
                bottom.append((i, sz)); bottomW += sz.width + margin
            }
        }

        let topH = top.map { $0.1.height }.max() ?? 0
        let topY: CGFloat = 18
        corridorY = topY + topH + 36
        let bottomY = corridorY + 36
        let bottomH = max(214, bottom.map { $0.1.height }.max() ?? 0)
        size = CGSize(width: max(780, topW, bottomW), height: bottomY + bottomH + 16)

        func place(_ index: Int, _ sz: CGSize, x: CGFloat, y: CGFloat, doorY: CGFloat) {
            let team = company.teams[index]
            let rect = CGRect(x: x, y: y, width: sz.width, height: sz.height)
            let tint = Self.palette[index % Self.palette.count]
            rooms.append(RoomSlot(team: team, rect: rect, door: CGPoint(x: rect.midX, y: doorY),
                                  corridor: CGPoint(x: rect.midX, y: corridorY), tint: tint))
            let cols = min(max(team.members.count, 1), 3)
            let firstX = rect.minX + (sz.width - CGFloat(cols - 1) * 121) / 2
            for (j, person) in team.members.enumerated() {
                let x = firstX + CGFloat(j % 3) * 121
                let deskY = rect.minY + 62 + CGFloat(j / 3) * 78
                desks.append(Desk(id: person.id, center: CGPoint(x: x, y: deskY)))
                homes[person.id] = CGPoint(x: x, y: deskY + 34)
                roomIndex[person.id] = rooms.count - 1
                seats.append(Seat(person: person, tint: tint))
            }
        }

        var x = margin
        for (i, sz) in top { place(i, sz, x: x, y: topY, doorY: topY + sz.height); x += sz.width + margin }
        x = margin
        for (i, sz) in bottom { place(i, sz, x: x, y: bottomY, doorY: bottomY); x += sz.width + margin }
        meeting = CGRect(x: x, y: bottomY, width: 168, height: bottomH)
        kitchen = CGRect(x: x + 168 + margin, y: bottomY, width: 182, height: bottomH)
    }
}

// MARK: - Simulation: people walk to the coffee machine, chat at the water cooler, stroll

@MainActor
final class OfficeSim: ObservableObject {
    @Published var pos: [String: CGPoint] = [:]
    @Published var bubble: [String: String] = [:]
    @Published var walking: Set<String> = []
    @Published var facing: [String: CGFloat] = [:]
    private var meetingActive = false

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
        meetingActive = false
        for (id, home) in layout.homes { pos[id] = home }
    }

    private func trigger() {
        guard busy.count < 8 else { return }
        let free = layout.homes.keys.filter { !busy.contains($0) && !isAssigned($0) }
        guard let a = free.randomElement() else { return }
        switch Int.random(in: 0..<10) {
        case 0..<3:
            coffee(a)
        case 3..<5:
            if let b = free.filter({ $0 != a }).randomElement() { chat(a, b) } else { coffee(a) }
        case 5..<8:
            if !meetingActive && free.count >= 3 {
                meeting(Array(free.shuffled().prefix(Int.random(in: 3...min(5, free.count)))))
            } else {
                stroll(a)
            }
        default:
            stroll(a)
        }
    }

    private func outRoute(_ id: String) -> [CGPoint] {
        guard let i = layout.roomIndex[id], i < layout.rooms.count else { return [] }
        let room = layout.rooms[i]
        return [room.door, room.corridor]
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

    private func coffee(_ id: String) {
        busy.insert(id)
        Task { @MainActor in
            let spot = layout.coffeeSpots.randomElement() ?? layout.coffeeSpots[0]
            let path = outRoute(id) + [layout.kitchenCorridor, layout.kitchenDoor, spot]
            let visited = await walk(id, path, abortable: true)
            if visited.count == path.count {
                bubble[id] = "\u{2615}"
                try? await Task.sleep(nanoseconds: UInt64.random(in: 4...7) * 1_000_000_000)
                bubble[id] = nil
            }
            await goHome(id, via: visited)
            busy.remove(id)
        }
    }

    /// A meeting: several people walk to the meeting room, sit around the table, take turns talking, then go back.
    private func meeting(_ people: [String]) {
        meetingActive = true
        busy.formUnion(people)
        Task { @MainActor in
            let center = CGPoint(x: layout.meeting.midX, y: layout.meeting.midY + 10)
            let entry = CGPoint(x: layout.meeting.midX, y: layout.meeting.minY + 44)
            let corridorEntry = CGPoint(x: layout.meeting.midX, y: layout.corridorY)
            let doorway = CGPoint(x: layout.meeting.midX, y: layout.meeting.minY)
            var paths: [String: [CGPoint]] = [:]
            var walkers: [String: Task<[CGPoint], Never>] = [:]
            for (i, id) in people.enumerated() {
                let angle = (Double(i) / Double(max(people.count, 1)) * 2 + 0.5) * Double.pi + Double.pi / 2
                let seat = CGPoint(x: center.x + CGFloat(cos(angle)) * 70, y: center.y + CGFloat(sin(angle)) * 46)
                let path = outRoute(id) + [corridorEntry, doorway, entry, seat]
                paths[id] = path
                walkers[id] = Task { @MainActor in await self.walk(id, path, abortable: true) }
            }
            var visited: [String: [CGPoint]] = [:]
            for id in people { visited[id] = await walkers[id]?.value ?? [] }
            let allArrived = people.allSatisfy { visited[$0]?.count == paths[$0]?.count }
            if allArrived {
                let rounds = Int.random(in: 4...6)
                for _ in 0..<rounds {
                    if Task.isCancelled { break }
                    let speaker = people.randomElement()
                    for id in people { bubble[id] = (id == speaker) ? (Bool.random() ? "\u{1F4CB}" : "\u{1F4AC}") : nil }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                for id in people { bubble[id] = nil }
            }
            var homeWalkers: [Task<Void, Never>] = []
            for id in people {
                let via = visited[id] ?? []
                homeWalkers.append(Task { @MainActor in await self.goHome(id, via: via) })
            }
            for t in homeWalkers { await t.value }
            for id in people { busy.remove(id) }
            meetingActive = false
        }
    }

    private func chat(_ a: String, _ b: String) {
        busy.insert(a)
        busy.insert(b)
        Task { @MainActor in
            let pathA = outRoute(a) + [layout.meetLeft]
            let pathB = outRoute(b) + [layout.meetRight]
            let ta = Task { @MainActor in await self.walk(a, pathA, abortable: true) }
            let tb = Task { @MainActor in await self.walk(b, pathB, abortable: true) }
            let va = await ta.value
            let vb = await tb.value
            if va.count == pathA.count && vb.count == pathB.count {
                bubble[a] = "\u{1F4AC}"
                bubble[b] = "\u{1F4AC}"
                try? await Task.sleep(nanoseconds: UInt64.random(in: 4...7) * 1_000_000_000)
                bubble[a] = nil
                bubble[b] = nil
            }
            let ha = Task { @MainActor in await self.goHome(a, via: va) }
            let hb = Task { @MainActor in await self.goHome(b, via: vb) }
            await ha.value
            await hb.value
            busy.remove(a)
            busy.remove(b)
        }
    }

    private func stroll(_ id: String) {
        busy.insert(id)
        Task { @MainActor in
            let target = CGPoint(x: CGFloat.random(in: 60...max(61, layout.size.width - 60)), y: layout.corridorY)
            let path = outRoute(id) + [target]
            let visited = await walk(id, path, abortable: true)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await goHome(id, via: visited)
            busy.remove(id)
        }
    }
}

// MARK: - Views

struct FloorPlanView: View {
    @ObservedObject var model: AppModel
    @StateObject private var sim = OfficeSim()

    var body: some View {
        let layout = OfficeLayout(company: model.company)
        GeometryReader { geo in
            let scale = min(max(geo.size.width / layout.size.width, 0.5), 1.6)
            office(layout)
                .frame(width: layout.size.width, height: layout.size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
        }
        .aspectRatio(layout.size.width / layout.size.height, contentMode: .fit)
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
            corridor(layout)
            ForEach(layout.rooms) { room in
                RoomView(model: model, room: room)
            }
            RoomBox(rect: layout.meeting, title: "Meeting Room", icon: "person.2.wave.2.fill")
            MeetingTable().position(x: layout.meeting.midX, y: layout.meeting.midY + 10)
            RoomBox(rect: layout.kitchen, title: "Kitchen", icon: "cup.and.saucer.fill")
            kitchenProps(layout)
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

    private func corridor(_ layout: OfficeLayout) -> some View {
        let w = layout.size.width
        let y = layout.corridorY
        return ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
                .frame(width: w - 32, height: 56).position(x: w / 2, y: y)
            HStack(spacing: 6) {
                Image(systemName: "building.2.fill")
                Text(model.company.name).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.green)
            .position(x: 100, y: y - 12)
            Image(systemName: "waterbottle.fill").foregroundStyle(.blue.opacity(0.6))
                .font(.system(size: 16)).position(x: w / 2, y: y - 12)
            Image(systemName: "leaf.fill").foregroundStyle(Theme.green.opacity(0.7)).position(x: w * 0.32, y: y + 16)
            Image(systemName: "leaf.fill").foregroundStyle(Theme.green.opacity(0.7)).position(x: w * 0.72, y: y + 16)
            Image(systemName: "leaf.fill").foregroundStyle(Theme.green.opacity(0.7)).position(x: w - 50, y: y + 16)
        }
        .allowsHitTesting(false)
    }

    private func kitchenProps(_ layout: OfficeLayout) -> some View {
        let k = layout.kitchen
        return ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.25)).frame(width: 34, height: 26)
                .overlay(Image(systemName: "cup.and.saucer.fill").font(.system(size: 13)).foregroundStyle(.white))
                .position(x: k.minX + 110, y: k.minY + 34)
            Image(systemName: "refrigerator.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                .position(x: k.minX + 158, y: k.minY + 36)
            Circle().fill(Color(red: 0.72, green: 0.55, blue: 0.38)).frame(width: 58, height: 58)
                .position(x: k.minX + 91, y: k.minY + min(150, k.height - 64))
            Image(systemName: "fork.knife").foregroundStyle(.secondary.opacity(0.6)).position(x: k.minX + 34, y: k.minY + 36)
        }
        .allowsHitTesting(false)
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
            .contextMenu { AgentContextMenu(model: model, person: seat.person) }
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
            HStack(spacing: 6) {
                Image(systemName: "door.left.hand.open").foregroundStyle(room.tint)
                Text(room.team.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(room.team.members.count) people").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(allSelected ? "Deselect room" : "Select room") { model.setTeamSelected(room.team, !allSelected) }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(room.tint)
                Button { model.companySheet = .newAgent(teamID: room.team.id) } label: {
                    Image(systemName: "person.badge.plus").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(room.tint)
                .disabled(room.team.members.count >= Company.maxMembers)
                .help(room.team.members.count >= Company.maxMembers ? "This team is full" : "Add an agent to \(room.team.name)")
            }
            .frame(width: room.rect.width - 28)
            .position(x: room.rect.midX, y: room.rect.minY + 20)
            Rectangle().fill(Theme.card).frame(width: 46, height: 8)
                .position(room.door).allowsHitTesting(false)
        }
    }
}

struct RoomBox: View {
    let rect: CGRect
    let title: String
    let icon: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04))
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.35), lineWidth: 4)
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            Label(title, systemImage: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .position(x: rect.midX, y: rect.minY + 20)
            Rectangle().fill(Theme.card).frame(width: 46, height: 8).position(x: rect.midX, y: rect.minY)
        }
        .allowsHitTesting(false)
    }
}

struct MeetingTable: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 40).fill(Color(red: 0.72, green: 0.55, blue: 0.38)).frame(width: 110, height: 52)
            ForEach(0..<6, id: \.self) { i in
                Circle().fill(Color.primary.opacity(0.22)).frame(width: 14, height: 14)
                    .offset(x: CGFloat(cos(Double(i) / 6 * 2 * .pi)) * 66, y: CGFloat(sin(Double(i) / 6 * 2 * .pi)) * 36)
            }
        }
        .allowsHitTesting(false)
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

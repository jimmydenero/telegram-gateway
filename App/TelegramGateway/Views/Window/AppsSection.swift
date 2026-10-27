import SwiftUI

/// Apps: a list on the left — requests waiting for a decision first, then the apps that have
/// access — and the selected one's detail on the right.
struct AppsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.screen != .main {
                GatewayUnavailable()
            } else if model.requests.isEmpty, model.grants.isEmpty {
                ContentUnavailableView(
                    "No apps yet", systemImage: "square.grid.2x2",
                    description: Text("When an app asks the gateway for access, it appears here for you to approve."))
            } else {
                HStack(spacing: 0) {
                    list
                        .frame(width: 236)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await model.loadAccess()
                if model.chats.isEmpty { await model.loadChats() }
                model.normalizeAppSelection()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var list: some View {
        @Bindable var model = model
        return List(selection: $model.selectedApp) {
            if !model.requests.isEmpty {
                Section("Wants access") {
                    ForEach(model.requests) { request in
                        HStack(spacing: 8) {
                            StatusDot(tone: .attention, size: 8)
                            TitleAndDetail(title: request.name, detail: Wording.timeLeft(until: request.expiresAt))
                        }
                        .padding(.vertical, 2)
                        .tag(AppSelection.request(request.requestId))
                    }
                }
            }
            if !model.grants.isEmpty {
                Section("Has access") {
                    ForEach(model.grants) { grant in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(grant.app.name)
                                    .font(TypeScale.rowTitle)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                TrailingState(tone: grant.state.tone, text: grant.state.text)
                            }
                            Text(grant.summary)
                                .font(TypeScale.secondary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(AppSelection.grant(grant.id))
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedApp {
        case .request(let id):
            if let request = model.request(id: id) {
                RequestDetailPane(request: request)
            } else {
                placeholder
            }
        case .grant(let id):
            if let grant = model.grant(id: id) {
                AppDetailPane(grant: grant)
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        Text("Select an app")
            .font(TypeScale.body)
            .foregroundStyle(.secondary)
    }
}

/// A pending request: who, what it does, what it wants, where, and the decision.
struct RequestDetailPane: View {
    @Environment(AppModel.self) private var model
    var request: AccessRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PanelSize.gap) {
                Card(tone: .attention, padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(request.name)
                                    .font(TypeScale.screenTitle)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("Wants access · \(Wording.timeLeft(until: request.expiresAt))")
                                    .font(TypeScale.secondary)
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            Text(request.description)
                                .font(TypeScale.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            FactRow("Wants") {
                                Text(Permission.sentence(request.scopes))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(Permission.sorted(request.scopes).joined(separator: ", "))
                            }
                            FactRow("In") { requestedChats }
                            if let url = request.webhookUrl {
                                FactRow("Sends to") {
                                    Text(Wording.host(of: url))
                                        .lineLimit(1)
                                        .help(url)
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Deny") { Task { await model.deny(request) } }
                            Button("Review…") {
                                Task {
                                    if model.chats.isEmpty { await model.loadChats() }
                                    model.beginApproval(request)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                }
                if let error = model.accessError {
                    Card(tone: .failed) {
                        Text(error).font(TypeScale.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(PanelSize.windowMargin)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var requestedChats: some View {
        let ids = request.requestedChats.chatIds
        if ids.isEmpty {
            Text("Any chats you choose")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ids, id: \.self) { id in
                    let status = request.requestedChatsStatus?.first { $0.chatId == id }
                    let monitored = model.chatsByID[id]?.isMonitored ?? status?.isMonitored ?? false
                    let title = Text(model.chatsByID[id]?.title ?? status?.title ?? id)
                    let note = Text("not monitored yet")
                        .font(TypeScale.secondary)
                        .foregroundStyle(Tone.attention.color)
                    if monitored {
                        title.lineLimit(1)
                    } else {
                        // The chat's name wins; the note drops below when both do not fit.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                title.fixedSize()
                                note.fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                title.lineLimit(1)
                                note
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One app's access in full, with Resume when its delivery is paused and Revoke.
struct AppDetailPane: View {
    @Environment(AppModel.self) private var model
    var grant: Grant
    @State private var confirmingRevoke = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PanelSize.gap) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(grant.app.name)
                                .font(TypeScale.screenTitle)
                            Spacer(minLength: 8)
                            TrailingState(tone: grant.state.tone, text: grant.state.text)
                        }
                        Text(grant.app.description)
                            .font(TypeScale.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if grant.needsAttention { delivery }
                    if !Permission.reading(grant.scopes).isEmpty {
                        LabeledSection("Can read") {
                            RowCard {
                                ForEach(Permission.reading(grant.scopes), id: \.self) { scope in
                                    TitleAndDetail(title: Permission.name(scope), detail: Permission.meaning(scope))
                                        .help(scope)
                                }
                            }
                        }
                    }
                    if !grant.scopes.filter({ Permission.actions.contains($0) }).isEmpty {
                        LabeledSection("Can act as you") {
                            RowCard {
                                ForEach(Permission.actions.filter { grant.scopes.contains($0) }, id: \.self) { scope in
                                    TitleAndDetail(title: Permission.name(scope), detail: Permission.meaning(scope)).help(scope)
                                }
                            }
                        }
                    }
                    LabeledSection(grant.chats.isFolder ? "Chats in the \(grant.chats.folderTitle ?? "") folder" : "Chats",
                                   footer: grant.chats.isFolder ? "Chats you add to the folder on your phone are included automatically." : nil) {
                        RowCard {
                            let ids = grant.chats.isFolder ? grant.effectiveChatIds : (grant.chats.chatIds ?? [])
                            if ids.isEmpty {
                                Text("None right now")
                                    .font(TypeScale.body)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(ids, id: \.self) { id in
                                let live = grant.effectiveChatIds.contains(id)
                                TitleAndDetail(
                                    title: model.chatsByID[id]?.title ?? id,
                                    detail: live ? model.chatsByID[id].map(Wording.chatSubtitle) : "No longer monitored — nothing is sent",
                                    detailTone: live ? .neutral : .attention)
                            }
                        }
                    }
                    if !grant.needsAttention { delivery }
                    if let error = model.accessError {
                        Card(tone: .failed) {
                            Text(error).font(TypeScale.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(PanelSize.windowMargin)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            BottomBar {
                Text("Access since \(grant.createdAt.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(TypeScale.secondary)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { confirmingRevoke = true } label: {
                    Text("Revoke access…").foregroundStyle(Tone.failed.color)
                }
            }
        }
        .confirmationDialog("Revoke \(grant.app.name)'s access?", isPresented: $confirmingRevoke) {
            Button("Revoke", role: .destructive) { Task { await model.revoke(grant) } }
        } message: {
            Text("It stops receiving messages immediately. This can't be undone; the app has to ask for access again.")
        }
    }

    @ViewBuilder
    private var delivery: some View {
        if let webhook = grant.webhook {
            switch webhook.state {
            case .paused:
                Card(tone: .attention) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Delivery paused")
                                .font(TypeScale.rowTitle)
                            Text("\(Wording.host(of: webhook.url)) stopped answering\(webhook.lastError.map { " (\($0))" } ?? ""). \(Wording.count(webhook.pendingEvents, "message")) waiting; none are lost.")
                                .font(TypeScale.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Resume") { Task { await model.resumeWebhook(grant) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            case .retrying:
                Card(tone: .attention) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delivery failing")
                            .font(TypeScale.rowTitle)
                        Text("\(Wording.host(of: webhook.url)) isn't answering\(webhook.lastError.map { " (\($0))" } ?? ""). The gateway keeps retrying for a day, then pauses.")
                            .font(TypeScale.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .active, .unknown:
                LabeledSection("Delivery") {
                    RowCard {
                        ValueRow("Sends to") { Text(Wording.host(of: webhook.url)).lineLimit(1).help(webhook.url) }
                        ValueRow("Last delivery", webhook.lastDeliveryAt.map { Wording.ago($0) } ?? "Nothing sent yet")
                    }
                }
            }
        } else {
            LabeledSection("Delivery") {
                RowCard {
                    ValueRow("Connects", "Directly to the gateway")
                    ValueRow("Last seen", grant.lastSeenAt.map { Wording.ago($0) } ?? "Not connected yet")
                }
            }
        }
    }
}

/// The review sheet: decide what one app gets — which chats, which permissions.
struct ApproveSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let draft = model.approval {
                ScrollView {
                    VStack(alignment: .leading, spacing: PanelSize.gap) {
                        Text("Give \(draft.request.name) access")
                            .font(TypeScale.screenTitle)

                        LabeledSection(draft.followFolder ? "Folder" : "Chats",
                                       footer: draft.followFolder ? "The app sees whatever is in the folder, including chats you add later." : nil) {
                            if draft.followFolder { folderCard(draft) } else { chatsCard(draft) }
                        }

                        if !Permission.reading(draft.request.scopes).isEmpty {
                            LabeledSection("Can read") {
                                RowCard(inset: 26) {
                                    ForEach(Permission.reading(draft.request.scopes), id: \.self) { scope in
                                        scopeToggle(scope)
                                    }
                                }
                            }
                        }
                        if !draft.request.scopes.filter({ Permission.actions.contains($0) }).isEmpty {
                            LabeledSection("Can act as you") {
                                RowCard(inset: 26) {
                                    ForEach(Permission.actions.filter { draft.request.scopes.contains($0) }, id: \.self) { scope in scopeToggle(scope) }
                                }
                            }
                        }

                        if let error = model.accessError {
                            Card(tone: .failed) {
                                Text(error).font(TypeScale.body).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(PanelSize.windowMargin)
                }
                BottomBar {
                    Text(model.approvalSummary(draft))
                        .font(TypeScale.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel") { model.cancelApproval() }
                        .keyboardShortcut(.cancelAction)
                    Button(model.approving ? "Approving…" : "Approve") { Task { await model.approve() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.approving || !model.canApprove(draft))
                }
            }
        }
        .frame(width: PanelSize.sheet.width, height: PanelSize.sheet.height)
        .task { if model.chats.isEmpty { await model.loadChats() } }
    }

    private func chatsCard(_ draft: ApprovalDraft) -> some View {
        RowCard(inset: 64) {
            ForEach(model.approvalChatIds(draft), id: \.self) { id in
                let chat = model.chatsByID[id]
                let monitored = chat?.isMonitored ?? false
                HStack(spacing: 10) {
                    Toggle("", isOn: chatBinding(id))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    IconTile(symbol: chat?.type.symbolName ?? "questionmark")
                    TitleAndDetail(
                        title: chat?.title ?? draft.request.requestedChatsStatus?.first { $0.chatId == id }?.title ?? id,
                        detail: monitored ? chat.map(Wording.chatSubtitle) : "Not monitored yet — approving starts monitoring it",
                        detailTone: monitored ? .neutral : .attention)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { chatBinding(id).wrappedValue.toggle() }
            }
            if model.otherMonitoredCount(draft) > 0, !draft.showOtherChats {
                linkRow("Show \(Wording.count(model.otherMonitoredCount(draft), "other monitored chat"))") {
                    model.approval?.showOtherChats = true
                }
            }
            if model.approvalChatIds(draft).isEmpty {
                Text("Nothing is monitored yet. Pick chats in Chats first.")
                    .font(TypeScale.body)
                    .foregroundStyle(.secondary)
            }
            linkRow("Follow a folder instead") {
                model.approval?.followFolder = true
                if model.approval?.folderId == nil {
                    model.approval?.folderId = model.folders.first(where: \.isMonitored)?.id
                }
            }
        }
    }

    private func folderCard(_ draft: ApprovalDraft) -> some View {
        RowCard(inset: 64) {
            let monitoredFolders = model.folders.filter(\.isMonitored)
            if monitoredFolders.isEmpty {
                Text("No folder is monitored. Tick one in Chats first.")
                    .font(TypeScale.body)
                    .foregroundStyle(.secondary)
            }
            ForEach(monitoredFolders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: draft.folderId == folder.id ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(draft.folderId == folder.id ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    IconTile(symbol: "folder")
                    TitleAndDetail(title: folder.title, detail: Wording.count(folder.chatIds.count, "chat"))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.approval?.folderId = folder.id }
                .accessibilityAddTraits(draft.folderId == folder.id ? .isSelected : [])
            }
            linkRow("Choose chats instead") { model.approval?.followFolder = false }
        }
    }

    private func linkRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(TypeScale.body)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            // Lines up with the titles above (past the checkbox and the icon).
            .padding(.leading, 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chatBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.approval?.chatIds.contains(id) ?? false },
            set: { on in
                if on { model.approval?.chatIds.insert(id) } else { model.approval?.chatIds.remove(id) }
            })
    }

    /// One permission with its checkbox, in the approval sheet.
    private func scopeToggle(_ scope: String) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: scopeBinding(scope))
                .toggleStyle(.checkbox)
                .labelsHidden()
            TitleAndDetail(title: Permission.name(scope), detail: Permission.meaning(scope))
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { scopeBinding(scope).wrappedValue.toggle() }
        .help(scope)
    }

    private func scopeBinding(_ scope: String) -> Binding<Bool> {
        Binding(
            get: { model.approval?.scopes.contains(scope) ?? false },
            set: { on in
                if on { model.approval?.scopes.insert(scope) } else { model.approval?.scopes.remove(scope) }
            })
    }
}

#Preview("Apps") {
    let model = AppModel.preview(.loggedIn)
    model.section = .apps
    return MainWindowView().environment(model).frame(width: 820, height: 560)
}

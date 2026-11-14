import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AuthCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: Logo.image).resizable().interpolation(.high).frame(width: 96, height: 96).accessibilityLabel("ChatKeep")
            VStack(spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) { content }.textFieldStyle(.roundedBorder).controlSize(.large)
        }
        .frame(width: 340).padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct SetupView: View {
    @EnvironmentObject private var store: ArchiveStore
    @Local private var password = ""
    @Local private var confirm = ""
    @Local private var busy = false
    @Local private var error: String?
    @FocusState private var focused: Bool

    private var problem: String? {
        if let p = PasswordPolicy.problem(password) { return p }
        if password != confirm { return "Passwords don't match." }
        return nil
    }

    var body: some View {
        AuthCard(title: "Create your archive",
                 subtitle: "Choose a password. It encrypts every conversation you import, and it can't be recovered if you forget it. Everything stays on this Mac.") {
            SecureField("Password", text: $password).focused($focused)
            SecureField("Confirm password", text: $confirm).onSubmit(create)
            StrengthMeter(password: password)
            if let msg = error ?? ((confirm.isEmpty && password.count < PasswordPolicy.minimumLength) ? nil : problem) {
                Text(msg).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: create) {
                Group { if busy { ProgressView().controlSize(.small) } else { Text("Create Archive") } }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(problem != nil || busy)
            if store.hasBackups { RestoreBackupButton(label: "Restore from a backup…") }
        }
        .onAppear { focused = true }
    }

    private func create() {
        guard problem == nil, !busy else { return }
        busy = true; error = nil
        Task {
            do { try await store.create(password: password) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct UnlockView: View {
    @EnvironmentObject private var store: ArchiveStore
    @Local private var password = ""
    @Local private var busy = false
    @Local private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        AuthCard(title: "ChatKeep is locked", subtitle: "Enter your password to unlock your archive.") {
            SecureField("Password", text: $password).focused($focused).onSubmit(unlock)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let wait = store.unlockBlockedUntil.map { Int($0.timeIntervalSince(context.date).rounded(.up)) } ?? 0
                VStack(spacing: 10) {
                    if wait > 0 {
                        Text("Too many failed attempts. Try again in \(wait)s.").font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let error {
                        Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(action: unlock) {
                        Group { if busy { ProgressView().controlSize(.small) } else { Text("Unlock") } }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || busy || wait > 0)
                }
            }
            if store.hasBackups { RestoreBackupButton(label: "Restore from a backup…") }
        }
        .onAppear { focused = true }
    }

    private func unlock() {
        guard !password.isEmpty, !busy else { return }
        busy = true; error = nil
        Task {
            do { try await store.unlock(password: password); password = "" }
            catch VaultError.throttled { self.error = nil; focused = true }
            catch { self.error = error.localizedDescription; password = ""; focused = true }
            busy = false
        }
    }
}

struct StrengthMeter: View {
    let password: String
    private var score: Int { PasswordPolicy.score(password) }
    private var label: String { ["Too short", "Weak", "Fair", "Good", "Strong"][score] }
    private var color: Color { [Color.red, .orange, .yellow, .green, .green][score] }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<4) { i in Capsule().fill(i < score ? color : Color.secondary.opacity(0.2)).frame(height: 4) }
            }
            Text(password.isEmpty ? " " : label).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
    }
}

struct RestoreBackupButton: View {
    @EnvironmentObject private var store: ArchiveStore
    let label: String
    @Local private var error: String?

    var body: some View {
        VStack(spacing: 4) {
            Button(label, action: pick).buttonStyle(.link).font(.callout)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.top, 6)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.title = "Choose a ChatKeep backup"
        panel.message = "Backups are encrypted with the password that was in use when they were made."
        panel.directoryURL = store.backupsURL
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.restore(from: url); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct ChangePasswordView: View {
    @EnvironmentObject private var store: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @Local private var current = ""
    @Local private var new = ""
    @Local private var confirm = ""
    @Local private var busy = false
    @Local private var error: String?

    private var valid: Bool { !current.isEmpty && PasswordPolicy.problem(new) == nil && new == confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Password").font(.title3.weight(.semibold))
            Text("Your archive is re-encrypted with a key from the new password and a fresh salt. Older backups, which use the old password, are removed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Current password", text: $current)
            SecureField("New password (12+ characters)", text: $new)
            SecureField("Confirm new password", text: $confirm)
            StrengthMeter(password: new)
            if !new.isEmpty, let p = PasswordPolicy.problem(new) { Text(p).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: change) { if busy { ProgressView().controlSize(.small) } else { Text("Change Password") } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid || busy)
            }
        }
        .textFieldStyle(.roundedBorder).padding(22).frame(width: 400)
    }

    private func change() {
        busy = true; error = nil
        Task {
            do { try await store.changePassword(current: current, new: new); dismiss() }
            catch VaultError.wrongPassword { error = "Current password is incorrect." }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

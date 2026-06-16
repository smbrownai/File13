import File13Core
import SwiftUI

struct EmptyStateView: View {
    let onAddAccount: () -> Void
    let onUseDemoData: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)

            Text("Connect a mail account")
                .font(.title2).bold()

            Text("File13 fetches message headers only — sender, subject, and date. Your password is stored in your Mac's Keychain.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            HStack(spacing: 12) {
                Button(action: onAddAccount) {
                    Label("Add IMAP Account", systemImage: "plus")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Try Demo Data", action: onUseDemoData)
                    .controlSize(.large)
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingStateView: View {
    let title: String
    let subtitle: String?
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            if let onCancel {
                Button("Cancel", role: .cancel, action: onCancel)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let message: String
    let onRetry: () -> Void
    let onAddAccount: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.red)
            Text("Couldn't connect").font(.title3).bold()
            Text(message).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Retry", action: onRetry)
                Button("Edit Account", action: onAddAccount)
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

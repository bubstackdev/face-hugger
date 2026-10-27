import AppKit
import SwiftUI

struct TransferHistoryView: View {
    @Bindable var model: AppModel
    @State private var visibleCount = 50
    @State private var selectedReceipt: TransferReceipt?
    @State private var confirmClear = false
    private var receipts: [TransferReceipt] { model.transferReceipts.filter { $0.outcome != .running } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if receipts.isEmpty {
                ContentUnavailableView("No transfer receipts", systemImage: "clock")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List {
                    ForEach(Array(receipts.prefix(visibleCount))) { receipt in
                        Button { selectedReceipt = receipt } label: {
                            HStack(spacing: 12) {
                                Image(systemName: receipt.outcome == .completed ? "checkmark.circle" : "clock.arrow.circlepath")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(receipt.sourceLabel).font(.system(size: 13, weight: .medium))
                                    Text(receipt.repo.name).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text(receipt.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(receipt.outcome.label).font(.system(size: 12)).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(receipt.sourceLabel), \(receipt.outcome.label), view receipt")
                        .contextMenu {
                            if let job = model.jobs.first(where: { $0.id == receipt.jobID }), job.state != .running {
                                Button("Remove queue item", role: .destructive) { model.remove(job.id) }
                            }
                        }
                    }
                    if receipts.count > visibleCount {
                        Button("Show more receipts") { visibleCount += 50 }
                    }
                }.frame(height: 240)
                HStack(alignment: .top) {
                    Text("The latest 200 finished receipts are kept on this Mac. Session logs are not retained.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear history…", role: .destructive) { confirmClear = true }
                }
            }
        }
        .sheet(item: $selectedReceipt) { receipt in TransferReceiptView(receipt: receipt) }
        .confirmationDialog("Clear saved transfer receipts?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { model.clearTransferHistory() }
        } message: {
            Text("Queue items, recovery checkpoints, and files on Hugging Face are kept. The active attempt is kept too.")
        }
    }
}

struct TransferReceiptView: View {
    let receipt: TransferReceipt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transfer receipt · \(receipt.sourceLabel)").font(.headline)
            ScrollView {
                Text(receipt.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy receipt", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(receipt.text, forType: .string)
                }
                Button(receipt.lastCommitURL != nil ? "Open last commit" : receipt.verifiedRevisionURL != nil ? "Open verified revision" : "Open repository", systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(receipt.lastCommitURL ?? receipt.verifiedRevisionURL ?? receipt.destinationURL)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680, height: 460)
    }
}

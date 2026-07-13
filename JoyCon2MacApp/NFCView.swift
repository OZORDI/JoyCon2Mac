import SwiftUI

struct NFCView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @State private var isScanning = false
    @State private var selectedTagID: String?

    private var selectedTag: NFCTag? {
        guard let selectedTagID else { return daemonBridge.nfcTags.first }
        return daemonBridge.nfcTags.first(where: { $0.id == selectedTagID }) ?? daemonBridge.nfcTags.first
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    Text("NFC Reader")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    Button(action: {
                        isScanning.toggle()
                        if isScanning {
                            daemonBridge.scanNFC()
                        } else {
                            daemonBridge.stopNFC()
                        }
                    }) {
                        HStack {
                            Image(systemName: isScanning ? "stop.circle.fill" : "wave.3.right.circle.fill")
                            Text(isScanning ? "Stop Scanning" : "Scan for Tags")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                Divider()
                
                // Scanning indicator
                if isScanning {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        
                        Text("Scanning for NFC tags...")
                            .foregroundColor(.secondary)
                        
                        Spacer()
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
                
                // Tag list
                if daemonBridge.nfcTags.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 64))
                            .foregroundColor(.secondary)
                        
                        Text("No NFC Tags Found")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Hold an NFC tag near the right Joy-Con stick and click Scan")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Detected Tags")
                                .font(.headline)
                            Text("\(daemonBridge.nfcTags.count) unique")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        
                        ForEach(daemonBridge.nfcTags) { tag in
                            NFCTagCard(tag: tag, isSelected: selectedTag?.id == tag.id)
                                .onTapGesture {
                                    selectedTagID = tag.id
                                }
                        }
                    }
                }
                
                // Tag details
                if let tag = selectedTag {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Tag Details")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            DetailRow(label: "UID", value: tag.uid)
                            DetailRow(label: "Type", value: tag.type)
                            DetailRow(label: "Status", value: tag.readMessage)
                            DetailRow(label: "Size", value: "\(tag.data.count) bytes")
                            DetailRow(label: "Taps", value: "\(tag.scanCount)")
                            DetailRow(label: "First Seen", value: formatDate(tag.firstSeen))
                            DetailRow(label: "Last Seen", value: formatDate(tag.lastSeen))
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)

                        if !tag.decodedRecords.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Decoded Data")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                ForEach(tag.decodedRecords) { record in
                                    DecodedRecordRow(record: record)
                                }
                            }
                        } else if tag.readStatus == 2 {
                            Text("The Joy-Con detected this tag, but its Amiibo reader rejected the tag format before exposing memory. Generic NDEF data is not available through this read profile.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else if tag.readStatus == 0 {
                            Text("Waiting for the Joy-Con to finish reading the tag.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("No URL, text, or NDEF record was present in the completed tag memory.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        // Hex dump
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Data (Hex)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            
                            ScrollView(.horizontal) {
                                Text(tag.data.map { String(format: "%02X", $0) }.joined(separator: " "))
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(8)
                                    .background(Color(NSColor.textBackgroundColor))
                                    .cornerRadius(4)
                            }
                        }
                        
                        // Actions
                        HStack(spacing: 12) {
                            Button("Copy UID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(tag.uid, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            
                            Button("Export Data") {
                                exportTagData(tag)
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .onChange(of: daemonBridge.nfcTags.first?.id) { newValue in
            if selectedTagID == nil {
                selectedTagID = newValue
            }
        }
        .onChange(of: daemonBridge.nfcTags.first?.lastSeen) { _ in
            selectedTagID = daemonBridge.nfcTags.first?.id
        }
        .onDisappear {
            if isScanning {
                isScanning = false
                daemonBridge.stopNFC()
            }
        }
    }
    
    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    
    func exportTagData(_ tag: NFCTag) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "nfc_tag_\(tag.uid).bin"
        panel.allowedContentTypes = [.data]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? tag.data.write(to: url)
            }
        }
    }
}

struct NFCTagCard: View {
    let tag: NFCTag
    let isSelected: Bool
    @State private var isFresh = false

    private var summaryText: String {
        if tag.readStatus != 1 {
            return tag.readMessage
        }
        if let record = tag.decodedRecords.first(where: { $0.label == "URL" || $0.label == "URI" }) {
            return record.value
        }
        if let record = tag.decodedRecords.first {
            return record.value
        }
        return "\(tag.data.count) bytes"
    }
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "wave.3.right.circle.fill")
                .font(.title)
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(tag.type)
                    .font(.headline)
                
                Text("UID: \(tag.uid)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(summaryText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(tag.readStatus == 1 ? "Read" : (tag.readStatus == 0 ? "Reading" : "Unsupported"))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(tag.readStatus == 1 ? .green : (tag.readStatus == 0 ? .blue : .orange))

                Text("\(tag.scanCount)x")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(tag.scanCount > 1 ? .blue : .secondary)

                Text(shortTime(tag.lastSeen))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background((isSelected || isFresh) ? Color.blue.opacity(isFresh ? 0.16 : 0.1) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected || isFresh ? Color.blue : Color.clear, lineWidth: 2)
        )
        .animation(.easeOut(duration: 0.18), value: isFresh)
        .animation(.easeOut(duration: 0.18), value: isSelected)
        .onChange(of: tag.scanCount) { _ in
            isFresh = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                isFresh = false
            }
        }
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

struct DecodedRecordRow: View {
    let record: NFCDecodedRecord

    private var openableURL: URL? {
        guard record.label == "URL" || record.label == "URI" else { return nil }
        if record.value.lowercased().hasPrefix("www.") {
            return URL(string: "https://\(record.value)")
        }
        return URL(string: record.value)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(record.label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 92, alignment: .leading)

            Text(record.value)
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(3)

            Spacer()

            if let url = openableURL {
                Button("Open") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
            }

            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.value, forType: .string)
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(.body)
                .textSelection(.enabled)
            
            Spacer()
        }
    }
}

#Preview {
    NFCView()
        .environmentObject(DaemonBridge.shared)
        .frame(width: 800, height: 600)
}

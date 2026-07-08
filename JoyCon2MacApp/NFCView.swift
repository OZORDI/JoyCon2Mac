import SwiftUI

struct NFCView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @State private var isScanning = false
    @State private var selectedTag: NFCTag?
    
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
                        Text("Detected Tags (\(daemonBridge.nfcTags.count))")
                            .font(.headline)
                        
                        ForEach(daemonBridge.nfcTags) { tag in
                            NFCTagCard(tag: tag, isSelected: selectedTag?.id == tag.id)
                                .onTapGesture {
                                    selectedTag = tag
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
                            DetailRow(label: "Size", value: "\(tag.data.count) bytes")
                            DetailRow(label: "Detected", value: formatDate(tag.timestamp))
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        
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
                
                Text("\(tag.data.count) bytes")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(isSelected ? Color.blue.opacity(0.1) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
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

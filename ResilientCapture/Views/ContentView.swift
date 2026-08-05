import SwiftUI
import PhotosUI

/// The single screen: the capture queue plus a way to add to it.
///
/// The model is owned upstream (by the `App`) and passed in; because it's
/// `@Observable`, reading `model.items` here is enough for this view to track
/// changes. Styled toward Apple HIG: inset-grouped cards, a floating material
/// status banner, and a prominent bottom capture action.
struct ContentView: View {
    let model: CaptureQueueModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var pickerItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var successDismissed = false

    private var visibleStatus: StatusMessage? {
        guard let message = model.statusMessage else { return nil }
        if message.tone == .success && successDismissed { return nil }
        return message
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.items.isEmpty {
                    emptyState
                } else {
                    queueList
                }
            }
            .navigationTitle("Captures")
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let status = visibleStatus {
                    StatusBannerView(message: status)
                        .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.items.isEmpty {
                    captureButton
                        .padding(.horizontal)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                        .background(.bar)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: visibleStatus)
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: model.items.isEmpty)
        }
        .task {
            await model.start()
            await AppLaunch.seedIfRequested(into: model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.resumeUploads() }
            }
        }
        .task(id: model.statusMessage) {
            successDismissed = false
            guard model.statusMessage?.tone == .success else { return }
            try? await Task.sleep(for: .seconds(3))
            successDismissed = true
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                isImporting = true
                defer { isImporting = false }
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    await model.enqueue(imageData: data)
                } else {
                    model.errorMessage = "Couldn't read the selected image."
                }
                pickerItem = nil
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var queueList: some View {
        List {
            Section {
                ForEach(model.items) { item in
                    CaptureRowView(
                        item: item,
                        loadThumbnail: { await model.thumbnail(for: item) },
                        onRetry: { Task { await model.retry(id: item.id) } }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if item.state == .failed {
                            Button {
                                Task { await model.retry(id: item.id) }
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                    }
                }
            } footer: {
                Text("Captures are encrypted on this device and uploaded securely in the background.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Captures Yet", systemImage: "camera.viewfinder")
        } description: {
            Text("Add an identity document or selfie. It's saved on this device the instant you pick it, then uploaded securely in the background.")
        } actions: {
            capturePicker {
                Label("Add Capture", systemImage: "plus")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    private var captureButton: some View {
        capturePicker {
            Group {
                if isImporting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Saving Capture…")
                    }
                } else {
                    Label("Add Capture", systemImage: "camera.fill")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(isImporting)
    }

    private func capturePicker<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            label()
        }
    }
}

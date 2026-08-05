import SwiftUI
import PhotosUI

/// The single screen: the capture queue plus a picker to add to it.
///
/// The model is owned upstream (by the `App`) and passed in; because it's
/// `@Observable`, reading `model.items` here is enough for this view to track
/// changes - no `@ObservedObject` wrapper needed.
struct ContentView: View {
    let model: CaptureQueueModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var pickerItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var successDismissed = false

    /// The banner to show, honouring auto-dismiss of the success message.
    private var visibleStatus: StatusMessage? {
        guard let message = model.statusMessage else { return nil }
        if message.tone == .success && successDismissed { return nil }
        return message
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let status = visibleStatus {
                    StatusBannerView(message: status)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Group {
                    if model.items.isEmpty {
                        ContentUnavailableView(
                            "No captures yet",
                            systemImage: "camera.viewfinder",
                            description: Text("Add an identity document or selfie. It's saved locally the instant you pick it, then uploaded in the background.")
                        )
                    } else {
                        List(model.items) { item in
                            CaptureRowView(
                                item: item,
                                imageURL: model.imageURL(for: item),
                                onRetry: { Task { await model.retry(id: item.id) } }
                            )
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: visibleStatus)
            .navigationTitle("Capture Queue")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "plus.circle.fill")
                            .accessibilityLabel("Add capture")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if isImporting {
                    ProgressView("Saving capture…")
                        .padding()
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
            }
        }
        .task {
            await model.start()
            await AppLaunch.seedIfRequested(into: model)
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the foreground re-drives anything interrupted while away.
            if phase == .active {
                Task { await model.resumeUploads() }
            }
        }
        .task(id: model.statusMessage) {
            // Auto-dismiss the success banner a few seconds after it appears.
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
                // Load the selected image bytes, then hand them to the model,
                // which persists before it ever shows up in the queue.
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
}

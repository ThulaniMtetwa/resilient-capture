import SwiftUI
import PhotosUI

/// The single screen: the capture queue plus a picker to add to it.
///
/// The model is owned upstream (by the `App`) and passed in; because it's
/// `@Observable`, reading `model.items` here is enough for this view to track
/// changes — no `@ObservedObject` wrapper needed.
struct ContentView: View {
    let model: CaptureQueueModel

    @State private var pickerItem: PhotosPickerItem?
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
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
                            onRetry: {}   // wired to the upload manager in Step 6
                        )
                    }
                    .listStyle(.plain)
                }
            }
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
            await model.load()
            await AppLaunch.seedIfRequested(into: model)
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

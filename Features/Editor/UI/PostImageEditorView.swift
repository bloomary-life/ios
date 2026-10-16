import PhotosUI
import SwiftUI
import UIKit

struct PostImageEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isCaptionFocused: Bool
    @State private var imageError: String?
    @State private var isLoadingImage = false
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var selectedItem: PhotosPickerItem?
    @State private var isImagePickerPresented = false
    @State private var didOpenInitialImagePicker = false
    @State private var image: UIImage?
    @State private var overlayText: String
    @State private var captionDragStartScreenPos: CGPoint? // Screen coords where current drag began
    @State private var textPosition = CGPoint(x: 0.5, y: 0.45)
    @State private var textScale: Double = 0.09
    @State private var textStyle: ImageEditorTextStyle = .lightOnDark
    @State private var textAlignment: TextAlignment = .center
    let maxImageBytes: Int
    let onDone: (LinkedInPostAttachment) -> Void

    init(initialImage: UIImage? = nil, maxImageBytes: Int = 5 * 1024 * 1024, onDone: @escaping (LinkedInPostAttachment) -> Void) {
        self.onDone = onDone
        self.maxImageBytes = maxImageBytes
        _image = State(initialValue: initialImage)
        _overlayText = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                controls
            }
            .background(Color.black)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        overlayText = ""
                    } label: {
                        Text("Clear")
                    }
                    .foregroundStyle(.white)
                    .disabled(overlayText.isEmpty)
                }
            }
            .onChange(of: overlayText) { _, _ in clampCaptionPosition() }
            .onChange(of: textScale) { _, _ in clampCaptionPosition() }
            .onChange(of: selectedItem) { _, newItem in
                loadImage(from: newItem)
            }
            .alert("Image could not be processed", isPresented: Binding(get: { imageError != nil }, set: { if !$0 { imageError = nil } })) {
                Button("OK", role: .cancel) { imageError = nil }
            } message: { Text(imageError ?? "") }
            .photosPicker(isPresented: $isImagePickerPresented, selection: $selectedItem, matching: .images)
            .onAppear {
                openInitialImagePicker()
            }
        }
        .tint(AppStyle.lime)
    }

    private var editorCanvas: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if let image {
                    let displaySize = Self.fittedCanvasSize(in: proxy.size)
                    EditedPostImageCanvas(
                        image: image,
                        overlayText: isCaptionFocused ? "" : overlayText,
                        textPosition: textPosition,
                        textScale: textScale,
                        textStyle: textStyle,
                        textAlignment: textAlignment,
                        canvasSize: displaySize
                    )
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay {
                        GeometryReader { canvasProxy in
                            captionField(in: canvasProxy.size)
                        }
                        .coordinateSpace(name: "captionCanvas")
                    }
                    .overlay(alignment: .leading) {
                        fontSizeSlider
                            .frame(height: min(260, displaySize.height * 0.48))
                            .padding(.leading, 14)
                    }
                } else {
                    emptyCanvas
                }
            }
        }
    }

    private var emptyCanvas: some View {
        Color.black
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if captionOverflows {
                Text("Caption exceeds four lines. Shorten it or reduce the font size before attaching.")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            textControls
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .background(Color.black)
    }

    private var textControls: some View {
        HStack(spacing: 14) {
            Button(isLoadingImage ? "Loading…" : "Replace image") { isImagePickerPresented = true }
                .foregroundStyle(.white)
                .disabled(isLoadingImage)
            Button {
                textStyle = textStyle.next
            } label: {
                Text("A")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(textStyle.foreground)
                    .frame(width: 42, height: 42)
                    .background(textStyle.background)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 1))
            }
            .accessibilityLabel("Toggle text style")

            Button {
                textAlignment = textAlignment.next
            } label: {
                Image(systemName: textAlignment.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Toggle text alignment")

            Button {
                finishEditedImage()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(AppStyle.lime)
                    .clipShape(Circle())
            }
            .foregroundStyle(AppStyle.ink)
            .disabled(image == nil || isLoadingImage || captionOverflows)
            .accessibilityLabel("Done")
        }
    }

    private var fontSizeSlider: some View {
        GeometryReader { proxy in
            let progress = (textScale - Self.textScaleRange.lowerBound)
                / (Self.textScaleRange.upperBound - Self.textScaleRange.lowerBound)
            let thumbY = (1 - progress) * proxy.size.height

            ZStack {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(width: 8)
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.42), lineWidth: 1)
                    }

                Circle()
                    .fill(.black.opacity(0.74))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.55), lineWidth: 1)
                    }
                    .position(
                        x: proxy.size.width / 2,
                        y: min(max(thumbY, 17), proxy.size.height - 17)
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateTextScale(from: value.location.y, height: proxy.size.height)
                    }
            )
        }
        .frame(width: 46)
        .padding(.vertical, 8)
        .background(.black.opacity(0.16))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Caption font size")
        .accessibilityValue("\(Int(textScale * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: textScale = min(Self.textScaleRange.upperBound, textScale + Self.textScaleStep)
            case .decrement: textScale = max(Self.textScaleRange.lowerBound, textScale - Self.textScaleStep)
            @unknown default: break
            }
        }
    }

    private func captionField(in size: CGSize) -> some View {
        TextField("Caption", text: $overlayText, axis: .vertical)
            .focused($isCaptionFocused)
            .font(.system(size: CGFloat(textScale) * size.width, weight: .bold))
            .foregroundStyle(isCaptionFocused ? textStyle.foreground : .clear)
            .multilineTextAlignment(textAlignment)
            .lineLimit(1...4)
            .minimumScaleFactor(0.45)
            .padding(.horizontal, size.width * 10 / 1080)
            .padding(.vertical, size.width * 6 / 1080)
            .frame(width: size.width * 0.82, height: ImageCaptionGeometry.boxHeight(overlayText, scale: textScale, width: size.width), alignment: textAlignment.frameAlignment)
            .background(isCaptionFocused ? textStyle.background : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .position(denormalize(textPosition, in: size))
            .shadow(radius: 1)
            .accessibilityLabel("Image caption")
            .accessibilityAction(named: Text("Move caption up")) { moveCaption(dx: 0, dy: -0.03) }
            .accessibilityAction(named: Text("Move caption down")) { moveCaption(dx: 0, dy: 0.03) }
            .accessibilityAction(named: Text("Move caption left")) { moveCaption(dx: -0.03, dy: 0) }
            .accessibilityAction(named: Text("Move caption right")) { moveCaption(dx: 0.03, dy: 0) }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = captionDragStartScreenPos ?? denormalize(textPosition, in: size)
                        captionDragStartScreenPos = start
                        updateTextPosition(CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height), in: size)
                    }
                    .onEnded { _ in captionDragStartScreenPos = nil }
            )
    }

    private func updateTextPosition(_ location: CGPoint, in size: CGSize) {
        textPosition = normalizedPoint(location, in: size)
    }

    private func updateTextScale(from y: CGFloat, height: CGFloat) {
        let clampedY = min(max(y, 0), max(1, height))
        let progress = 1 - (clampedY / max(1, height))
        let rawValue = Self.textScaleRange.lowerBound
            + (Self.textScaleRange.upperBound - Self.textScaleRange.lowerBound) * Double(progress)
        textScale = (rawValue / Self.textScaleStep).rounded() * Self.textScaleStep
    }

    private func denormalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func normalizedPoint(_ location: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(location.x / max(1, size.width), 0.41), 0.59),
            y: min(max(location.y / max(1, size.height), captionHalfHeight(in: size)), 1 - captionHalfHeight(in: size))
        )
    }

    private func moveCaption(dx: CGFloat, dy: CGFloat) {
        textPosition.x += dx
        textPosition.y += dy
        clampCaptionPosition()
    }

    private func clampCaptionPosition() {
        textPosition = normalizedPoint(denormalize(textPosition, in: Self.canvasSize), in: Self.canvasSize)
    }

    private func captionHalfHeight(in size: CGSize) -> CGFloat {
        min(0.5, ImageCaptionGeometry.boxHeight(overlayText, scale: textScale, width: size.width) / max(1, size.height) / 2)
    }

    private func openInitialImagePicker() {
        guard !didOpenInitialImagePicker, image == nil else { return }
        didOpenInitialImagePicker = true
        isImagePickerPresented = true
    }

    private func loadImage(from item: PhotosPickerItem?) {
        guard let item else { return }
        imageLoadTask?.cancel()
        isLoadingImage = true
        imageLoadTask = Task {
            defer { if selectedItem == item { isLoadingImage = false } }
            do {
                guard let data = try await item.loadTransferable(type: Data.self), let loadedImage = UIImage(data: data) else {
                    throw SyncedDraftsError.server("This photo could not be decoded. Choose another image.")
                }
                guard !Task.isCancelled, selectedItem == item else { return }
                image = loadedImage
                isCaptionFocused = true
            } catch {
                guard !Task.isCancelled, selectedItem == item else { return }
                imageError = error.localizedDescription
            }
        }
    }

    private var captionOverflows: Bool {
        ImageCaptionGeometry.textHeight(overlayText, scale: textScale, width: Self.canvasSize.width) >
            UIFont.boldSystemFont(ofSize: CGFloat(textScale) * Self.canvasSize.width).lineHeight * 4 + 1
    }

    @MainActor
    private func finishEditedImage() {
        guard let image, !captionOverflows else { return }
        let renderer = ImageRenderer(
            content: EditedPostImageCanvas(
                image: image,
                overlayText: overlayText,
                textPosition: textPosition,
                textScale: textScale,
                textStyle: textStyle,
                textAlignment: textAlignment,
                canvasSize: Self.canvasSize
            )
            .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        )
        renderer.scale = 1
        guard let rendered = renderer.uiImage,
              let data = rendered.jpegData(compressionQuality: 1) else {
            imageError = "Image export failed. Try replacing the image."
            return
        }
        guard data.count <= maxImageBytes else {
            imageError = "Export exceeds the server image limit (\(maxImageBytes) bytes). Choose a smaller image."
            return
        }
        onDone(LinkedInPostAttachment(
            data: data,
            filename: "bloomary-linkedin-image.jpg",
            mimeType: "image/jpeg"
        ))
        dismiss()
    }

    private static let canvasSize = CGSize(width: 1080, height: 1350)
    private static let textScaleRange: ClosedRange<Double> = 0.055...0.14
    private static let textScaleStep = 0.005

    private static func fittedCanvasSize(in size: CGSize) -> CGSize {
        let ratio = canvasSize.width / canvasSize.height
        let widthByHeight = size.height * ratio
        if widthByHeight <= size.width {
            return CGSize(width: widthByHeight, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / ratio)
    }

}

private struct EditedPostImageCanvas: View {
    let image: UIImage
    let overlayText: String
    let textPosition: CGPoint
    let textScale: Double
    let textStyle: ImageEditorTextStyle
    let textAlignment: TextAlignment
    let canvasSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if !overlayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(overlayText)
                        .font(.system(size: scaledTextSize(in: proxy.size), weight: .bold))
                        .foregroundStyle(textStyle.foreground)
                        .multilineTextAlignment(textAlignment)
                        .lineLimit(4)
                        .minimumScaleFactor(0.45)
                        .padding(.horizontal, proxy.size.width * 10 / 1080)
                        .padding(.vertical, proxy.size.width * 6 / 1080)
                        .frame(width: proxy.size.width * 0.82, height: ImageCaptionGeometry.boxHeight(overlayText, scale: textScale, width: proxy.size.width), alignment: textAlignment.frameAlignment)
                        .background(textStyle.background)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .position(denormalize(textPosition, in: proxy.size))
                        .shadow(radius: 1)
                }

            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipped()
    }

    private func denormalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func scaledTextSize(in size: CGSize) -> CGFloat {
        CGFloat(textScale) * size.width
    }

}

private enum ImageCaptionGeometry {
    static func textHeight(_ text: String, scale: Double, width: CGFloat) -> CGFloat {
        let font = UIFont.boldSystemFont(ofSize: CGFloat(scale) * width)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width * 0.82 - width * 20 / 1080, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        return max(font.lineHeight, ceil(bounds.height))
    }

    static func boxHeight(_ text: String, scale: Double, width: CGFloat) -> CGFloat {
        min(textHeight(text, scale: scale, width: width), UIFont.boldSystemFont(ofSize: CGFloat(scale) * width).lineHeight * 4) + width * 12 / 1080
    }
}

private enum ImageEditorTextStyle: CaseIterable {
    case lightOnDark
    case darkOnLight
    case lightTransparent

    var foreground: Color {
        switch self {
        case .lightOnDark, .lightTransparent:
            return .white
        case .darkOnLight:
            return .black
        }
    }

    var background: Color {
        switch self {
        case .lightOnDark:
            return .black.opacity(0.55)
        case .darkOnLight:
            return .white.opacity(0.86)
        case .lightTransparent:
            return .clear
        }
    }

    var next: ImageEditorTextStyle {
        switch self {
        case .lightOnDark:
            return .darkOnLight
        case .darkOnLight:
            return .lightTransparent
        case .lightTransparent:
            return .lightOnDark
        }
    }
}

private extension TextAlignment {
    var frameAlignment: Alignment {
        switch self {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    var systemImage: String {
        switch self {
        case .leading:
            return "text.alignleft"
        case .center:
            return "text.aligncenter"
        case .trailing:
            return "text.alignright"
        }
    }

    var next: TextAlignment {
        switch self {
        case .center:
            return .leading
        case .leading:
            return .trailing
        case .trailing:
            return .center
        }
    }
}

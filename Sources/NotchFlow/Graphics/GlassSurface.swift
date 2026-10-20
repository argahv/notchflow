import SwiftUI
import MetalKit

struct NativeMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow
        view.blendingMode = .behindWindow; view.state = .active; return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Uniforms shared with `LiquidGlass.metal`; layout must match `GlassUniforms` there.
struct GlassUniforms {
    var size: SIMD2<Float>
    var capture: SIMD2<Float>
    var ear: Float
    var corner: Float
    var band: Float
    var padding: Float = 0
}

/// Ultra: refracts the captured region behind the surface through a signed-distance model of the
/// actual silhouette, so bends, dispersion and edge light follow the morphing notch. Draws only
/// when a new frame or a new shape arrives; there is no display link.
struct RefractiveGlass: NSViewRepresentable {
    let image: CGImage
    let form: SurfaceForm
    let band: CGFloat
    let capture: CGSize
    func makeCoordinator() -> Renderer { Renderer() }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.clearColor = MTLClearColorMake(0, 0, 0, 0); view.layer?.isOpaque = false
        view.colorPixelFormat = .bgra8Unorm; view.framebufferOnly = true
        view.isPaused = true; view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator; context.coordinator.load()
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        let renderer = context.coordinator
        renderer.image = image
        renderer.uniforms = GlassUniforms(size: SIMD2(Float(form.size.width), Float(form.size.height)),
                                          capture: SIMD2(Float(max(1, capture.width)), Float(max(1, capture.height))),
                                          ear: Float(form.ear), corner: Float(form.corner), band: Float(band))
        view.setNeedsDisplay(view.bounds)
    }
    final class Renderer: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        var image: CGImage? { didSet { if image !== oldValue { texture = nil } } }
        var uniforms = GlassUniforms(size: .one, capture: .one, ear: 0, corner: 0, band: 0)
        private var texture: MTLTexture?
        private lazy var loader: MTKTextureLoader? = device.map(MTKTextureLoader.init)
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        func load() {
            guard let device, let url = Bundle.main.url(forResource: "LiquidGlass", withExtension: "metal"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else { return }
            do {
                let library = try device.makeLibrary(source: source, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "glassVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                queue = device.makeCommandQueue()
            } catch { NSLog("NotchFlow Metal fallback: %@", error.localizedDescription) }
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            if texture == nil, let image { texture = try? loader?.newTexture(cgImage: image, options: [.SRGB: false]) }
            guard let texture, let pipeline, let command = queue?.makeCommandBuffer(),
                  let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            var uniforms = self.uniforms
            encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlassUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding(); command.present(drawable); command.commit()
        }
    }
}

import Foundation
import Metal
import MetalKit

/// Displays a decoded MCT RGBA8 surface through the native iOS Metal pipeline.
@MainActor
public final class RE4MetalTexturePreviewRenderer: NSObject, MTKViewDelegate {
    private struct Vertex { var position: SIMD2<Float>; var uv: SIMD2<Float> }
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var texture: MTLTexture

    public init(view: MTKView, texture: MTLTexture, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else {
            throw NSError(domain: "RE4MetalPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal device is unavailable"])
        }
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "RE4MetalPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create MTLCommandQueue"])
        }
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        let shader = #"""
        #include <metal_stdlib>
        using namespace metal;
        struct RE4Vertex { float2 position; float2 uv; };
        struct RE4Varying { float4 position [[position]]; float2 uv; };
        vertex RE4Varying re4_preview_vertex(uint vid [[vertex_id]], constant RE4Vertex *vertices [[buffer(0)]]) {
            RE4Varying out; out.position = float4(vertices[vid].position, 0.0, 1.0); out.uv = vertices[vid].uv; return out;
        }
        fragment float4 re4_preview_fragment(RE4Varying in [[stage_in]], texture2d<float> image [[texture(0)]], sampler smp [[sampler(0)]]) {
            return image.sample(smp, in.uv);
        }
        """#
        let library = try device.makeLibrary(source: shader, options: nil)
        guard let vertex = library.makeFunction(name: "re4_preview_vertex"),
              let fragment = library.makeFunction(name: "re4_preview_fragment") else {
            throw NSError(domain: "RE4MetalPreview", code: 3, userInfo: [NSLocalizedDescriptionKey: "Metal shader entry point missing"])
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw NSError(domain: "RE4MetalPreview", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create sampler"])
        }
        self.sampler = sampler
        self.commandQueue = queue
        self.texture = texture
        super.init()
        view.framebufferOnly = true
        view.clearColor = MTLClearColorMake(0.02, 0.02, 0.02, 1.0)
        view.delegate = self
        view.enableSetNeedsDisplay = false
        view.isPaused = false
    }

    public func setTexture(_ texture: MTLTexture) { self.texture = texture }
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let quad: [Vertex] = [
            Vertex(position: SIMD2<Float>(-1, -1), uv: SIMD2<Float>(0, 1)),
            Vertex(position: SIMD2<Float>( 1, -1), uv: SIMD2<Float>(1, 1)),
            Vertex(position: SIMD2<Float>(-1,  1), uv: SIMD2<Float>(0, 0)),
            Vertex(position: SIMD2<Float>( 1,  1), uv: SIMD2<Float>(1, 0))
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        quad.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                encoder.setVertexBytes(UnsafeRawPointer(base), length: buffer.count * MemoryLayout<Vertex>.stride, index: 0)
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: quad.count)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}

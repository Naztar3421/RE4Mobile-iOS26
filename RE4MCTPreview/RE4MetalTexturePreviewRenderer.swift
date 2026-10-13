import Foundation
import Metal
import MetalKit

/// Displays a decoded MCT surface with aspect-fit scaling and diagnostic transparency preview.
@MainActor
public final class RE4MetalTexturePreviewRenderer: NSObject, MTKViewDelegate {
    private struct Vertex { var position: SIMD2<Float>; var uv: SIMD2<Float> }
    private struct PreviewParams { var blackAsTransparent: UInt32 }
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var texture: MTLTexture
    private var blackAsTransparent = false

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
        struct RE4PreviewParams { uint blackAsTransparent; };

        vertex RE4Varying re4_preview_vertex(uint vid [[vertex_id]], constant RE4Vertex *vertices [[buffer(0)]]) {
            RE4Varying out;
            out.position = float4(vertices[vid].position, 0.0, 1.0);
            out.uv = vertices[vid].uv;
            return out;
        }

        fragment float4 re4_preview_fragment(
            RE4Varying in [[stage_in]],
            texture2d<float> image [[texture(0)]],
            sampler smp [[sampler(0)]],
            constant RE4PreviewParams &params [[buffer(0)]]
        ) {
            float4 c = image.sample(smp, in.uv);
            if (params.blackAsTransparent != 0u && c.r <= (1.0 / 255.0) &&
                c.g <= (1.0 / 255.0) && c.b <= (1.0 / 255.0)) {
                c.a = 0.0;
            }

            // Composite real source alpha (and optional diagnostic black-key alpha)
            // over a checkerboard so transparent pixels remain distinguishable
            // even though the MTKView itself is opaque.
            float tile = fmod(floor(in.uv.x * 16.0) + floor(in.uv.y * 8.0), 2.0);
            float3 bg = mix(float3(0.20, 0.22, 0.24), float3(0.38, 0.40, 0.42), tile);
            float3 rgb = c.rgb * c.a + bg * (1.0 - c.a);
            return float4(rgb, 1.0);
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
            throw NSError(domain: "RE4MetalPreview", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create sampler state"])
        }
        self.sampler = sampler
        self.commandQueue = queue
        self.texture = texture
        super.init()
        view.framebufferOnly = true
        view.clearColor = MTLClearColorMake(0.025, 0.03, 0.035, 1.0)
        view.delegate = self
        view.enableSetNeedsDisplay = false
        view.isPaused = false
    }

    public func setTexture(_ texture: MTLTexture) { self.texture = texture }

    /// Diagnostic mode only: interpret exact/near-black pixels as transparent-looking
    /// pixels over a checkerboard. This is not asserted to be the original game's blend rule.
    public func setBlackAsTransparentPreview(_ enabled: Bool) {
        blackAsTransparent = enabled
    }

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

        // Fit the full texture inside the view without stretching its 512x256 aspect ratio.
        let drawableWidth = Double(view.drawableSize.width)
        let drawableHeight = Double(view.drawableSize.height)
        let textureAspect = Double(texture.width) / Double(texture.height)
        let viewAspect = drawableWidth / max(drawableHeight, 1)
        var viewport = MTLViewport(originX: 0, originY: 0, width: drawableWidth,
                                   height: drawableHeight, znear: 0, zfar: 1)
        if viewAspect > textureAspect {
            viewport.width = drawableHeight * textureAspect
            viewport.originX = (drawableWidth - viewport.width) / 2
        } else {
            viewport.height = drawableWidth / textureAspect
            viewport.originY = (drawableHeight - viewport.height) / 2
        }

        var params = PreviewParams(blackAsTransparent: blackAsTransparent ? 1 : 0)
        encoder.setViewport(viewport)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<PreviewParams>.stride, index: 0)
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

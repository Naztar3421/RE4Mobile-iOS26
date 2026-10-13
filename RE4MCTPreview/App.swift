import SwiftUI
import MetalKit

@main
struct RE4MCTPreviewApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("RE4 MCT / Metal Preview")
                .font(.title2.bold())
            Text("Metal rendering smoke test")
                .foregroundStyle(.secondary)
            MetalPreview()
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("This build tests native Metal rendering only. It does not run the game engine.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct MetalPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MTKViewDelegate {
        private var pipeline: MTLRenderPipelineState?
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?

        func attach(_ view: MTKView) {
            guard let device = view.device,
                  let queue = device.makeCommandQueue() else { return }
            self.device = device
            self.commandQueue = queue
            let source = """
            #include <metal_stdlib>
            using namespace metal;
            struct VOut { float4 position [[position]]; float2 uv; };
            vertex VOut vertexMain(uint id [[vertex_id]]) {
                float2 p[3] = { float2(-1.0,-1.0), float2(3.0,-1.0), float2(-1.0,3.0) };
                VOut o; o.position = float4(p[id],0,1); o.uv = (p[id]+1.0)*0.5; return o;
            }
            fragment float4 fragmentMain(VOut in [[stage_in]]) {
                float checker = fmod(floor(in.uv.x*8.0)+floor(in.uv.y*8.0),2.0);
                float3 a = float3(0.08,0.18,0.28);
                float3 b = float3(0.78,0.30,0.10);
                return float4(mix(a,b,checker),1.0);
            }
            """
            do {
                let library = try device.makeLibrary(source: source, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
                descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("Metal pipeline creation failed: \(error)")
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline, let commandQueue,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let command = commandQueue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }
    }
}

// One triangle on the GPU, made to be found in a hypervisor trace
// (docs/gpu/plan.md, phase 1; tools/hv/trace_agx_raw.py).
//
// Renders off-screen into a 64x64 BGRA texture, reads the centre pixel back
// to prove the GPU drew it, and prints when each command buffer ran. The
// data carries constants that are easy to search for in a snapshot:
//   vertex buffer  positions, then the marker floats 1234.5, 2345.5, 3456.5,
//                  4567.5 (0x449a5000 0x45129800 0x45580800 0x458eb400)
//   colour buffer  0.25 0.5 0.75 1.0, then the u32 marker 0xc0ffee01 + frame
//   clear colour   0.125 0.25 0.375 1.0
// It waits before the first frame and between frames so its submissions
// stand apart from the rest of macOS's GPU traffic.
//
// After the last frame it holds its GPU objects for --hold seconds before
// exiting (macOS frees them at exit), so a snapshot can still find them.
//
//   metal-triangle [--frames N] [--delay SECONDS] [--gap SECONDS] [--hold SECONDS] [--busy]
//
// Build on a Mac: swiftc -O triangle.swift -o metal-triangle

import Foundation
import Metal

func arg(_ name: String, _ def: Double) -> Double {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count, let v = Double(a[i + 1]) { return v }
    return def
}

let frames = Int(arg("--frames", 3))
let delay = arg("--delay", 10)
let gap = arg("--gap", 5)
let hold = arg("--hold", 180)

func stamp(_ what: String) {
    let t = Date().timeIntervalSince1970
    print(String(format: "%.6f %@", t, what))
    fflush(stdout)
}

guard let device = MTLCreateSystemDefaultDevice() else {
    print("no Metal device"); exit(1)
}
stamp("device \(device.name) (registryID \(device.registryID))")

let source = """
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; };
vertex V vs(uint vid [[vertex_id]], const device float2 *p [[buffer(0)]]) {
    V o; o.pos = float4(p[vid], 0.0, 1.0); return o;
}
fragment float4 fs(const device float4 *c [[buffer(0)]]) { return c[0]; }
"""

let library: MTLLibrary
do { library = try device.makeLibrary(source: source, options: nil) } catch {
    print("shader compile failed: \(error)"); exit(1)
}
let desc = MTLRenderPipelineDescriptor()
desc.label = "nixos-m4pro triangle pipeline"
desc.vertexFunction = library.makeFunction(name: "vs")
desc.fragmentFunction = library.makeFunction(name: "fs")
desc.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try! device.makeRenderPipelineState(descriptor: desc)

let size = 64
let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
texDesc.usage = [.renderTarget, .shaderRead]
texDesc.storageMode = .private
let target = device.makeTexture(descriptor: texDesc)!
target.label = "nixos-m4pro triangle target"

// Positions (a triangle covering the centre), then the marker floats.
let verts: [Float] = [0.0, 0.8, -0.8, -0.8, 0.8, -0.8, 1234.5, 2345.5, 3456.5, 4567.5]
let vbuf = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared)!
vbuf.label = "nixos-m4pro triangle vertices"
let readback = device.makeBuffer(length: size * size * 4, options: .storageModeShared)!
let queue = device.makeCommandQueue()!
// Colour for --busy frames, with its own marker word (0xc0ffeeb0).
let busyWords: [UInt32] = [0x3e800000, 0x3f000000, 0x3f400000, 0x3f800000, 0xc0ffeeb0]
let busyColour = device.makeBuffer(bytes: busyWords, length: busyWords.count * 4, options: .storageModeShared)!
busyColour.label = "nixos-m4pro triangle busy colour"
queue.label = "nixos-m4pro triangle queue"

stamp("ready; first frame in \(delay) s")
Thread.sleep(forTimeInterval: delay)

for frame in 0..<frames {
    var colour: [UInt32] = [0, 0, 0, 0, 0xc0ffee01 &+ UInt32(frame)]
    let rgba: [Float] = [0.25, 0.5, 0.75, 1.0]
    memcpy(&colour, rgba, 16)
    let cbuf = device.makeBuffer(bytes: colour, length: colour.count * 4, options: .storageModeShared)!
    cbuf.label = "nixos-m4pro triangle colour \(frame)"

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.125, green: 0.25, blue: 0.375, alpha: 1)
    pass.colorAttachments[0].storeAction = .store

    let cmd = queue.makeCommandBuffer()!
    cmd.label = "nixos-m4pro triangle frame \(frame)"
    let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
    enc.label = "nixos-m4pro triangle draw"
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(vbuf, offset: 0, index: 0)
    enc.setFragmentBuffer(cbuf, offset: 0, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    let blit = cmd.makeBlitCommandEncoder()!
    blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: size, height: size, depth: 1), to: readback,
              destinationOffset: 0, destinationBytesPerRow: size * 4, destinationBytesPerImage: size * size * 4)
    blit.endEncoding()

    stamp("frame \(frame): commit")
    cmd.commit()
    cmd.waitUntilCompleted()
    let p = readback.contents().assumingMemoryBound(to: UInt8.self)
    let centre = (size / 2 * size + size / 2) * 4
    let corner = 0
    stamp(String(format: "frame %d: done, GPU %.6f..%.6f (%.3f ms), status %d, centre BGRA %d %d %d %d, corner %d %d %d %d",
                 frame, cmd.gpuStartTime, cmd.gpuEndTime, (cmd.gpuEndTime - cmd.gpuStartTime) * 1000,
                 cmd.status.rawValue, p[centre], p[centre + 1], p[centre + 2], p[centre + 3],
                 p[corner], p[corner + 1], p[corner + 2], p[corner + 3]))
    if frame + 1 < frames { Thread.sleep(forTimeInterval: gap) }
}
// Expected: centre ~ 191 128 64 255 (the triangle), corner ~ 96 64 32 255 (the clear colour).
// --busy: keep drawing through the hold. Metal makes resources resident in
// the GPU's page tables only while command buffers using them are in
// flight; an idle hold left nothing mapped for a snapshot to find.
let busy = CommandLine.arguments.contains("--busy")
if busy {
    stamp("finished; drawing continuously for \(hold) s (--busy)")
    let end = Date().addingTimeInterval(hold)
    var n = 0
    var last: MTLCommandBuffer? = nil
    while Date() < end {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.125, green: 0.25, blue: 0.375, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let cmd = queue.makeCommandBuffer()!
        cmd.label = "nixos-m4pro triangle busy"
        let enc = cmd.makeRenderCommandEncoder(descriptor: pass)!
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setFragmentBuffer(busyColour, offset: 0, index: 0)
        for _ in 0..<64 { enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3) }
        enc.endEncoding()
        cmd.commit()
        n += 1
        // Keep a few frames in flight, never an unbounded queue.
        if n % 4 == 0 { last?.waitUntilCompleted() }
        last = cmd
    }
    last?.waitUntilCompleted()
    stamp("busy: \(n) command buffers")
} else {
    stamp("finished; holding the GPU objects for \(hold) s")
    Thread.sleep(forTimeInterval: hold)
}
withExtendedLifetime((vbuf, readback, target, pipeline, queue, busyColour)) {}
stamp("exiting")

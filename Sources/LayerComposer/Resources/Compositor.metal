#include <metal_stdlib>
using namespace metal;

// One pass over the canvas: base colour, then the blurred background (bilinear upscale from half
// resolution), then the foreground. Every input is premultiplied, so each step is `src + dst·(1 − src.a)`.

struct CompositorVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle from the vertex id, no vertex buffer. uv has a top-left origin like textures.
vertex CompositorVertexOut compositorVertex(uint vertexID [[vertex_id]]) {
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    CompositorVertexOut out;
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    out.uv = uv;
    return out;
}

fragment half4 compositorFragment(CompositorVertexOut in [[stage_in]],
                                  texture2d<half> background [[texture(0)]],
                                  texture2d<half> foreground [[texture(1)]],
                                  constant float4 &baseColor [[buffer(0)]]) {
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);

    half4 color = half4(baseColor);
    half4 blurred = background.sample(bilinear, in.uv);
    color = blurred + color * (1.0h - blurred.a);
    // The foreground is canvas-sized: read it texel for texel.
    half4 front = foreground.read(uint2(in.position.xy));
    return front + color * (1.0h - front.a);
}

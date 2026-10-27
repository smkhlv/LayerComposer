#include <metal_stdlib>
using namespace metal;

// The preview: the composited canvas drawn into the drawable's aspect-fit viewport, bilinear.

struct PreviewVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle over the viewport from the vertex id, no vertex buffer. uv has a top-left origin.
vertex PreviewVertexOut previewVertex(uint vertexID [[vertex_id]]) {
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    PreviewVertexOut out;
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    out.uv = uv;
    return out;
}

fragment half4 previewFragment(PreviewVertexOut in [[stage_in]],
                               texture2d<half> canvas [[texture(0)]]) {
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    return canvas.sample(bilinear, in.uv);
}

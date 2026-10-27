#include <metal_stdlib>
using namespace metal;

// A photo aspect-filled into the background target and centred.

struct ImageBackgroundVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle from the vertex id, no vertex buffer. uv has a top-left origin like textures.
vertex ImageBackgroundVertexOut imageBackgroundVertex(uint vertexID [[vertex_id]]) {
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    ImageBackgroundVertexOut out;
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    out.uv = uv;
    return out;
}

// `visible` is the fraction of the image along each axis that covers the target (≤ 1).
fragment half4 imageBackgroundFragment(ImageBackgroundVertexOut in [[stage_in]],
                                       texture2d<half> image [[texture(0)]],
                                       constant float2 &visible [[buffer(0)]]) {
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
    return image.sample(bilinear, 0.5 + (in.uv - 0.5) * visible);
}

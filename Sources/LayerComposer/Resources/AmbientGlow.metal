#include <metal_stdlib>
using namespace metal;

// The card's colours extruded outwards: each pixel samples the colour field at the card's nearest
// point (rotated around the card centre), weighted by exp(−d / falloff). Output is premultiplied;
// alpha is the weight, so the base colour shows through far from the card.

// Mirrors AmbientGlowUniforms in AmbientGlowLayer.swift. Positions and distances in canvas pixels.
struct AmbientGlowUniforms {
    float2 canvasPerTarget;
    float2 cardOrigin;
    float2 cardSize;
    float2 cardCentre;
    float2 rotation;      // (cos, sin)
    float inverseFalloff;
    float brightness;
};

struct AmbientGlowVertexOut {
    float4 position [[position]];
};

// Fullscreen triangle from the vertex id, no vertex buffer.
vertex AmbientGlowVertexOut ambientGlowVertex(uint vertexID [[vertex_id]]) {
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    AmbientGlowVertexOut out;
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return out;
}

fragment half4 ambientGlowFragment(AmbientGlowVertexOut in [[stage_in]],
                                   texture2d<half> field [[texture(0)]],
                                   constant AmbientGlowUniforms &u [[buffer(0)]]) {
    constexpr sampler bilinear(filter::linear, address::clamp_to_edge);

    // position.xy is the target pixel centre, top-left origin.
    float2 p = in.position.xy * u.canvasPerTarget;
    float2 nearest = clamp(p, u.cardOrigin, u.cardOrigin + u.cardSize);
    float d = distance(p, nearest);

    float2 offset = nearest - u.cardCentre;
    float2 turned = float2(u.rotation.x * offset.x - u.rotation.y * offset.y,
                           u.rotation.y * offset.x + u.rotation.x * offset.y);
    float2 uv = (u.cardCentre + turned - u.cardOrigin) / u.cardSize;

    float weight = min(exp(-d * u.inverseFalloff) * u.brightness, 1.0);
    return field.sample(bilinear, uv) * half(weight);
}

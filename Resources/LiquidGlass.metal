#include <metal_stdlib>
using namespace metal;

struct VertexOut { float4 position [[position]]; float2 uv; };

/// Must match `GlassUniforms` in GlassSurface.swift.
struct GlassUniforms {
    float2 size;     // surface size in points
    float2 capture;  // captured top-centre region in points
    float ear;       // concave flare at the top edge
    float corner;    // bottom corner radius
    float band;      // menu-bar band height (drawn solid black above the glass)
    float padding;
};

vertex VertexOut glassVertex(uint id [[vertex_id]]) {
    const float2 points[] = { {-1, 1}, {-1, -1}, {1, 1}, {1, -1} };
    const float2 uvs[] = { {0, 0}, {0, 1}, {1, 0}, {1, 1} };
    return { float4(points[id], 0, 1), uvs[id] };
}

/// Rounded box with a radius per corner (x: bottom-right, y: top-right, z: bottom-left, w: top-left),
/// y pointing down. Negative inside.
float roundedBox(float2 p, float2 halfSize, float4 r) {
    r.xy = (p.x > 0.0) ? r.xy : r.zw;
    float radius = (p.y > 0.0) ? r.x : r.y;
    float2 q = abs(p) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

/// The notch silhouette: flat top against the bezel, rounded bottom corners, body inset by the ears.
float silhouette(float2 p, constant GlassUniforms &u) {
    float2 halfSize = float2(max(1.0, u.size.x * 0.5 - u.ear), u.size.y * 0.5);
    return roundedBox(p, halfSize, float4(u.corner, 0.0, u.corner, 0.0));
}

fragment float4 glassFragment(VertexOut in [[stage_in]], texture2d<float> background [[texture(0)]],
                              constant GlassUniforms &u [[buffer(0)]]) {
    constexpr sampler sample(filter::linear, address::clamp_to_edge);
    float2 p = (in.uv - 0.5) * u.size;
    float distance = silhouette(p, u);

    // Surface normal from the distance field's gradient.
    const float e = 0.75;
    float2 normal = normalize(float2(silhouette(p + float2(e, 0), u) - silhouette(p - float2(e, 0), u),
                                     silhouette(p + float2(0, e), u) - silhouette(p - float2(0, e), u)) + 1e-4);

    // Light bends most within ~12 pt of the rim and not at all in the middle, like a thick lens edge.
    float rim = exp(-abs(distance) / 12.0);
    // Map this pixel to the same screen point inside the captured top-centre region.
    float2 screen = float2((u.capture.x - u.size.x) * 0.5, 0.0) + in.uv * u.size;
    float2 lens = screen / u.capture;
    float2 bend = normal * rim * (14.0 / u.capture);

    // Slight dispersion: red bends a little more than blue.
    float r = background.sample(sample, lens + bend * 1.05).r;
    float g = background.sample(sample, lens + bend).g;
    float b = background.sample(sample, lens + bend * 0.95).b;
    float3 color = float3(r, g, b) * 0.62;

    // Fresnel-like rim glow and a directional glint on the lower edges, lit from below-left.
    float fresnel = pow(rim, 2.2) * 0.12;
    float glint = pow(max(dot(normal, normalize(float2(-0.35, 1.0))), 0.0), 6.0) * rim * 0.22;
    // Nothing above the band shows; fade the effect in below it.
    float belowBand = smoothstep(u.band, u.band + 24.0, in.uv.y * u.size.y);
    return float4(color + (fresnel + glint) * belowBand, 1.0);
}

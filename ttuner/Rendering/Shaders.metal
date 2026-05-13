#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float writeHeadNorm;   // [0,1) position of newest column in ring texture
    float dbFloor;
    float dbCeil;
    float zoomMinLog;      // log(minHz)
    float zoomMaxLog;      // log(maxHz)
    float fftMinLog;       // log(displayedMinHz)
    float fftMaxLog;       // log(displayedMaxHz)
    float nowTime;         // seconds since renderer start
    float visibleSeconds;  // seconds visible across the screen
    float isLandscape;     // 0 or 1
    float scrubOffsetNorm; // 0 when live; >0 when paused, time offset in [0,1)
    float pitchTrailCount; // currently rendered count
    float showHeatmap;     // 1 when intonation heatmap is active
    float bandSizeNorm;    // edge band width in normalized screen coords
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut vs_fullscreen(uint vid [[vertex_id]]) {
    float2 pos[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    VSOut out;
    out.position = float4(pos[vid], 0, 1);
    out.uv = (pos[vid] + 1.0) * 0.5;
    return out;
}

fragment float4 fs_spectrogram(VSOut in [[stage_in]],
                                texture2d<float> spectro [[texture(0)]],
                                texture1d<float> colormap [[texture(1)]],
                                constant Uniforms& U [[buffer(0)]]) {
    float timeNorm = (U.isLandscape > 0.5) ? in.uv.x : (1.0 - in.uv.y);
    float freqNorm = (U.isLandscape > 0.5) ? (1.0 - in.uv.y) : in.uv.x;

    float ringX = fract(U.writeHeadNorm - (1.0 - timeNorm) - U.scrubOffsetNorm);
    float fLog = mix(U.zoomMinLog, U.zoomMaxLog, freqNorm);
    float ringY = (fLog - U.fftMinLog) / max(1e-6, (U.fftMaxLog - U.fftMinLog));
    ringY = clamp(ringY, 0.0, 1.0);

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float v = spectro.sample(s, float2(ringX, ringY)).r;

    float vn = saturate((v - U.dbFloor) / max(1e-6, (U.dbCeil - U.dbFloor)));

    constexpr sampler cs(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 col = colormap.sample(cs, vn);
    col.a *= smoothstep(0.0, 0.08, vn);
    return col;
}

// --- Beat markers -----------------------------------------------------------

struct BeatVertexIn {
    float along;
    float across;
    float accent;   // 0..3 (Accent enum)
    float track;    // 0=primary, 1=secondary, 2=subdivision, 3=countIn
};

struct BeatVSOut {
    float4 position [[position]];
    float accent;
    float track;
};

vertex BeatVSOut vs_beat(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          constant BeatVertexIn* verts [[buffer(0)]],
                          constant Uniforms& U [[buffer(1)]]) {
    BeatVertexIn v = verts[iid * 2 + vid];
    BeatVSOut out;
    float2 pos = (U.isLandscape > 0.5) ? float2(v.along, v.across) : float2(v.across, v.along);
    out.position = float4(pos, 0, 1);
    out.accent = v.accent;
    out.track = v.track;
    return out;
}

fragment float4 fs_beat(BeatVSOut in [[stage_in]]) {
    // Base alpha from accent level.
    float baseAlpha = (in.accent >= 2.5)      ? 0.95
                    : (in.accent >= 1.5)      ? 0.55
                                              : 0.25;
    // Color by track:
    //  primary (0)      → white
    //  secondary (1)    → cyan
    //  subdivision (2)  → low-alpha white (dotted appearance handled via line dash on CPU)
    //  countIn (3)      → amber
    float3 color;
    float alpha = baseAlpha;
    if (in.track >= 2.5) {        // countIn
        color = float3(1.0, 0.78, 0.30);
        alpha = 0.85;
    } else if (in.track >= 1.5) { // subdivision
        color = float3(1.0, 1.0, 1.0);
        alpha *= 0.4;
    } else if (in.track >= 0.5) { // secondary
        color = float3(0.45, 0.92, 1.0);
    } else {                      // primary
        color = float3(1.0, 1.0, 1.0);
    }
    return float4(color, alpha);
}

// --- Pitch trail ------------------------------------------------------------

struct PitchVertexIn {
    float along;
    float across;
    float clarity;
};

struct PitchVSOut {
    float4 position [[position]];
    float clarity;
};

vertex PitchVSOut vs_pitch(uint vid [[vertex_id]],
                            constant PitchVertexIn* verts [[buffer(0)]],
                            constant Uniforms& U [[buffer(1)]]) {
    PitchVertexIn v = verts[vid];
    float2 pos = (U.isLandscape > 0.5) ? float2(v.along, v.across) : float2(v.across, v.along);
    PitchVSOut out;
    out.position = float4(pos, 0, 1);
    out.clarity = v.clarity;
    return out;
}

fragment float4 fs_pitch(PitchVSOut in [[stage_in]]) {
    float alpha = (in.clarity > 0.85)
        ? 1.0
        : smoothstep(0.4, 0.85, in.clarity);
    return float4(1.0, 0.85, 0.45, alpha);
}

// --- Intonation Heatmap (edge band) ----------------------------------------

struct HeatmapVertexIn {
    float along;     // along the timeline
    float across;    // -1 = far edge, +1 = inner edge of band
    float magnitude; // 0..1 normalized |cents| / 50
};

struct HeatmapVSOut {
    float4 position [[position]];
    float magnitude;
    float across;
};

vertex HeatmapVSOut vs_heatmap(uint vid [[vertex_id]],
                                constant HeatmapVertexIn* verts [[buffer(0)]],
                                constant Uniforms& U [[buffer(1)]]) {
    HeatmapVertexIn v = verts[vid];
    // The band lives along the bottom (portrait) or left (landscape) edge.
    // `across` is in [-1, +1] where -1 is the far edge of screen and +1 is `band` inwards.
    float band = U.bandSizeNorm;  // typically 0.04
    float pos1d = -1.0 + (v.across + 1.0) * 0.5 * band;
    float2 pos = (U.isLandscape > 0.5) ? float2(v.along, pos1d) : float2(pos1d, v.along);
    HeatmapVSOut out;
    out.position = float4(pos, 0, 1);
    out.magnitude = v.magnitude;
    out.across = v.across;
    return out;
}

fragment float4 fs_heatmap(HeatmapVSOut in [[stage_in]]) {
    // green (low) → amber (mid) → red (high)
    float m = saturate(in.magnitude);
    float3 lo = float3(0.10, 0.80, 0.45);
    float3 mid = float3(0.96, 0.60, 0.18);
    float3 hi = float3(0.94, 0.27, 0.27);
    float3 c = m < 0.5
        ? mix(lo, mid, m * 2.0)
        : mix(mid, hi, (m - 0.5) * 2.0);
    // Slight inner fade so the band has a soft edge inward.
    float edgeFade = smoothstep(1.0, 0.4, in.across);
    return float4(c, 0.85 * edgeFade);
}

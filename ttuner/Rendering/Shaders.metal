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
    // 1) UV → time / frequency axes (swap depending on orientation)
    float timeNorm = (U.isLandscape > 0.5) ? in.uv.x : (1.0 - in.uv.y);  // 1 = newest
    float freqNorm = (U.isLandscape > 0.5) ? (1.0 - in.uv.y) : in.uv.x;

    // 2) Time axis → ring texture x
    float ringX = fract(U.writeHeadNorm - (1.0 - timeNorm) - U.scrubOffsetNorm);

    // 3) Frequency axis → log-mapped row in [0,1]
    float fLog = mix(U.zoomMinLog, U.zoomMaxLog, freqNorm);
    float ringY = (fLog - U.fftMinLog) / max(1e-6, (U.fftMaxLog - U.fftMinLog));
    ringY = clamp(ringY, 0.0, 1.0);

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float v = spectro.sample(s, float2(ringX, ringY)).r;

    // 4) Normalize dB → [0,1]
    float vn = saturate((v - U.dbFloor) / max(1e-6, (U.dbCeil - U.dbFloor)));

    constexpr sampler cs(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 col = colormap.sample(cs, vn);
    // Soft noise gate near the floor
    col.a *= smoothstep(0.0, 0.08, vn);
    return col;
}

// --- Beat markers -----------------------------------------------------------

struct BeatVertexIn {
    float along;   // [-1,1] position along the timeline axis (1 = newest)
    float across;  // [-1,1] across the screen (line endpoints)
    float accent;  // 0..3
};

struct BeatVSOut {
    float4 position [[position]];
    float accent;
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
    return out;
}

fragment float4 fs_beat(BeatVSOut in [[stage_in]]) {
    float a;
    if (in.accent >= 2.5)      a = 0.95;
    else if (in.accent >= 1.5) a = 0.55;
    else                       a = 0.25;
    return float4(1.0, 1.0, 1.0, a);
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

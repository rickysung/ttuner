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
    float scrubOffsetNorm; // 0 when live; >0 when paused, normalized to ring period
    float pitchTrailCount; // currently rendered count
    float showHeatmap;     // 1 when intonation heatmap is active
    float bandSizeNorm;    // edge band width in normalized screen coords
    float rmsFloor;        // dB mapped to 0 width
    float rmsCeil;         // dB mapped to max width
    float rmsMaxHalfWidth; // fraction of half-screen used at peak RMS
    float visibleRingFrac; // fraction of the ring buffer that fits the screen (visibleSec / ringSec)
    float vignetteStrength;// 0..1; 0 = off, 1 = strong corner darkening
    float rmsOpacity;      // 0..1; constant opacity multiplier for the volume bars
    float texelW;          // 1 / textureColumns (for in-shader smoothing)
    float texelH;          // 1 / textureRows
    float spectroBlur;     // 0 = no shader blur, 1 = full 5-tap weight
    float scrubOffsetSeconds; // mirror of scrubOffsetNorm but in seconds, for beat markers
    float cameraSemitone;     // smoothed current pitch in MIDI semitones
    float semitoneSpacing;    // NDC.x per semitone
    float pitchInTune;        // 0..1 where 1 = within ±5 cents
    float emitterX;
    float emitterY;
    float viewAspect;         // viewport width / height — used to keep particles round
    float particleSize;       // NDC.x radius at peak life
    float emitterPulse;       // 0..1 audio-driven brightness modulator
    float flameSway;          // external lateral sway applied only to the tail
    float flameTailMax;       // ly cutoff for the cosine taper — louder = longer
    float scrubActive;        // 0 = live, 1 = user is inspecting history
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

    // The visible window covers only `visibleRingFrac` of the full ring,
    // so map the screen-time axis through that compressed window.
    float ringX = fract(U.writeHeadNorm
                        - (1.0 - timeNorm) * U.visibleRingFrac
                        - U.scrubOffsetNorm);
    float fLog = mix(U.zoomMinLog, U.zoomMaxLog, freqNorm);
    float ringY = (fLog - U.fftMinLog) / max(1e-6, (U.fftMaxLog - U.fftMinLog));
    ringY = clamp(ringY, 0.0, 1.0);

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    // 5-tap cross-shaped blur to soften visible column/row boundaries. The
    // hardware linear filter already blends within each texel; this adds a
    // half-texel reach to both neighbouring columns and frequency bins.
    float v = spectro.sample(s, float2(ringX, ringY)).r;
    if (U.spectroBlur > 0.001) {
        float vL = spectro.sample(s, float2(ringX - U.texelW, ringY)).r;
        float vR = spectro.sample(s, float2(ringX + U.texelW, ringY)).r;
        float vU = spectro.sample(s, float2(ringX, max(0.0, ringY - U.texelH))).r;
        float vD = spectro.sample(s, float2(ringX, min(1.0, ringY + U.texelH))).r;
        float blurred = 0.40 * v + 0.15 * (vL + vR + vU + vD);
        v = mix(v, blurred, U.spectroBlur);
    }

    float vn = saturate((v - U.dbFloor) / max(1e-6, (U.dbCeil - U.dbFloor)));

    constexpr sampler cs(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 col = colormap.sample(cs, vn);
    col.a *= smoothstep(0.0, 0.08, vn);

    // Soft corner vignette for a more cinematic feel.
    if (U.vignetteStrength > 0.001) {
        float2 vc = in.uv - 0.5;
        float vd2 = dot(vc, vc);            // 0 center, 0.5 corners
        float v01 = smoothstep(0.06, 0.55, vd2);
        col.rgb *= 1.0 - v01 * U.vignetteStrength;
    }
    return col;
}

// --- Beat markers -----------------------------------------------------------

struct BeatVertexIn {
    float secondsSinceStart; // wall-clock time the marker happened, relative to renderer start
    float accent;            // 0..3 (Accent enum)
    float track;             // 0=primary, 1=secondary, 2=subdivision, 3=countIn
};

struct BeatVSOut {
    float4 position [[position]];
    float along;             // -1..+1 across the screen, perpendicular to time
    float perp;              // -1..+1 across the line's thickness
    float accent;
    float track;
};

// Each beat is now an instanced quad (4 verts) instead of a 1-pixel line.
// The extra geometry lets the fragment fade alpha gracefully at the
// screen edges (vignette) and feather across the line thickness, so
// markers read as soft glowing capsules rather than mathematical
// hairlines.
vertex BeatVSOut vs_beat(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          constant BeatVertexIn* verts [[buffer(0)]],
                          constant Uniforms& U [[buffer(1)]]) {
    BeatVertexIn v = verts[iid];
    // Quad corners (triangle strip): vid 0,1 = bottom row, 2,3 = top.
    float along = (vid % 2 == 0) ? -1.0 : 1.0;
    float perp  = (vid < 2)      ? -1.0 : 1.0;

    // Time → position along the time axis. flame center = "now".
    float flameNow = (U.isLandscape > 0.5) ? U.emitterX : U.emitterY;
    float effectiveNow = U.nowTime - U.scrubOffsetSeconds;
    float dt = effectiveNow - v.secondsSinceStart;
    float timePos = 2.0 * (dt / max(0.001, U.visibleSeconds)) + flameNow;

    // Line thickness in NDC along the time axis. Keep it small — the
    // fragment shader feathers the edges further.
    const float halfThickness = 0.006;
    BeatVSOut out;
    if (U.isLandscape > 0.5) {
        // Landscape: time axis = X, line axis = Y.
        out.position = float4(timePos + perp * halfThickness, along, 0, 1);
    } else {
        // Portrait: line axis = X, time axis = Y.
        out.position = float4(along, timePos + perp * halfThickness, 0, 1);
    }
    out.along = along;
    out.perp = perp;
    out.accent = v.accent;
    out.track = v.track;
    return out;
}

fragment float4 fs_beat(BeatVSOut in [[stage_in]]) {
    // Base alpha from accent level.
    float baseAlpha = (in.accent >= 2.5)      ? 0.95
                    : (in.accent >= 1.5)      ? 0.55
                                              : 0.25;
    // Color by track.
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
    // Vignette along the line — bright in the middle, fades to 0 at
    // the screen edges. Exponent 6 keeps the bright zone wide and only
    // the last ~15 % of either side falls off, which is enough to lose
    // the "hard ruler" feel without losing visual presence near center.
    float edgeFade = 1.0 - pow(saturate(abs(in.along)), 6.0);
    // Gaussian-like falloff across the line thickness — turns the quad
    // into a soft capsule instead of a flat rectangle.
    float crossFade = exp(-3.5 * in.perp * in.perp);
    alpha *= edgeFade * crossFade;
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

// --- Reference grid (vertical semitone lines) ------------------------------

fragment float4 fs_refgrid(VSOut in [[stage_in]],
                            constant Uniforms& U [[buffer(0)]]) {
    // Position on the chromatic axis. `cameraSemitone` shifts the grid so
    // the line nearest the player's current pitch hovers around the center.
    float xNDC = in.uv.x * 2.0 - 1.0;
    float worldSemi = xNDC / max(1e-4, U.semitoneSpacing) + U.cameraSemitone;
    float k = round(worldSemi);
    float lineXNDC = (k - U.cameraSemitone) * U.semitoneSpacing;
    float dist = abs(xNDC - lineXNDC);

    // Natural notes (C major) form the heavier grid; accidentals are
    // rendered as faint hairlines between them.
    // Bitmask 0xAD5 = {0,2,4,5,7,9,11} (C, D, E, F, G, A, B).
    int kMod = int(fmod(fmod(k, 12.0) + 12.0, 12.0));
    bool isNatural = ((1 << kMod) & 0xAD5) != 0;

    float halfWidth = isNatural ? 0.0030 : 0.0015;
    float baseAlpha = isNatural ? 0.42 : 0.16;

    float aa = fwidth(dist) * 1.2;
    float lineMask = smoothstep(halfWidth + aa, halfWidth - aa, dist);

    // Fade the entire grid near top/bottom of screen so it doesn't compete
    // with the floating cards.
    float vFade = smoothstep(0.02, 0.10, in.uv.y) * smoothstep(0.02, 0.10, 1.0 - in.uv.y);

    float alpha = lineMask * baseAlpha * vFade;
    return float4(0.96, 0.97, 1.0, alpha);
}

// --- Pitch timeline dots ---------------------------------------------------

struct PitchDotVertexIn {
    float secondsSinceStart;
    float semitone;          // continuous MIDI
    float clarity;           // 0..1
    float rmsDb;
};

struct PitchDotVSOut {
    float4 position [[position]];
    float2 local;            // -1..1 quad corner
    float clarity;
    float rmsNorm;           // 0..1
    float ageFade;
    float inTune;
};

vertex PitchDotVSOut vs_pitchdot(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  constant PitchDotVertexIn* dots [[buffer(0)]],
                                  constant Uniforms& U [[buffer(1)]]) {
    PitchDotVertexIn d = dots[iid];

    // Newest pitch event is born at the flame; older dots trail upward as
    // they age. The user reads the flame as "now", so anchoring the trail
    // origin to it keeps the meaning unambiguous.
    float flameNow = (U.isLandscape > 0.5) ? U.emitterX : U.emitterY;
    float effectiveNow = U.nowTime - U.scrubOffsetSeconds;
    float dt = effectiveNow - d.secondsSinceStart;
    float along = 2.0 * (dt / max(0.001, U.visibleSeconds)) + flameNow;

    // Pitch → horizontal position via camera
    float xNDC = (d.semitone - U.cameraSemitone) * U.semitoneSpacing;

    // Quad corner offsets (triangle strip, 4 verts).
    float2 corner;
    switch (vid) {
        case 0: corner = float2(-1, -1); break;
        case 1: corner = float2( 1, -1); break;
        case 2: corner = float2(-1,  1); break;
        case 3: corner = float2( 1,  1); break;
    }

    // Dot radius is dominated by loudness. A sub-bass hum is a near-pinprick;
    // a strong fortissimo plant prints a fat dot 10× wider. Power < 1 spends
    // more of the dynamic range on the audible mid-loudness band so the
    // difference reads at a glance.
    float rmsNormSize = saturate((d.rmsDb + 65.0) / 55.0);
    float volPow = pow(rmsNormSize, 0.55);
    float size = (0.0025 + 0.040 * volPow) * (0.80 + 0.30 * d.clarity);
    float2 center = (U.isLandscape > 0.5) ? float2(along, xNDC) : float2(xNDC, along);
    float2 offset = corner * float2(size, size * U.viewAspect);

    PitchDotVSOut out;
    out.position = float4(center + offset, 0, 1);
    out.local = corner;
    out.clarity = d.clarity;
    // Map rms -65..-10 to 0..1
    out.rmsNorm = saturate((d.rmsDb + 65.0) / 55.0);
    // Older points dim down for a gentle history trail.
    out.ageFade = saturate(1.0 - dt / max(0.001, U.visibleSeconds));
    // Closer to integer semitone → more in tune.
    float frac = d.semitone - floor(d.semitone);
    float cents = (frac > 0.5 ? (1.0 - frac) : frac) * 100.0;
    out.inTune = 1.0 - smoothstep(5.0, 30.0, cents);
    return out;
}

fragment float4 fs_pitchdot(PitchDotVSOut in [[stage_in]]) {
    float d2 = dot(in.local, in.local);
    if (d2 > 1.0) discard_fragment();
    float core = pow(1.0 - d2, 1.7);
    float3 inTuneColor = float3(0.25, 0.62, 1.0);
    float3 offColor = float3(1.0, 0.78, 0.42);
    float3 col = mix(offColor, inTuneColor, in.inTune);
    float alpha = core * (0.18 + 0.55 * in.clarity) * (0.35 + 0.65 * in.rmsNorm) * in.ageFade;
    return float4(col, alpha);
}

// --- Emitter flame (flat 2D vector style, layered) -------------------------

// Half-width of the flame at normalized height `ly` for a tail that
// terminates at `tailMax`. The base bulges outward (fireball belly),
// then a cosine taper necks down to zero at `tailMax`. C¹ smooth at the
// seam (ly = 0).
//   ly < 0          → expanding half-ellipse (1.35 × radius at ly=0).
//   0 ≤ ly<tailMax  → cosine taper from 1.35 to 0.
//   ly ≥ tailMax    → 0
static float fs_flame_profile(float ly, float tailMax) {
    const float BASE_W = 1.35;
    if (ly < 0.0) {
        return BASE_W * sqrt(max(0.0, 1.0 - ly * ly));
    } else if (ly < tailMax) {
        return BASE_W * cos((ly / tailMax) * 1.5707963);
    }
    return 0.0;
}

// ---------------------------------------------------------------------------
// Theme-specific fragments. Each visual theme provides its own emitter,
// particle, and (optional) background fragment. The renderer wires them
// up via VisualTheme.swift; vertex stages stay shared.
// ---------------------------------------------------------------------------

fragment float4 fs_emitter_flame(VSOut in [[stage_in]],
                                  constant Uniforms& U [[buffer(0)]]) {
    float2 ndc = in.uv * 2.0 - 1.0;
    float2 d = ndc - float2(U.emitterX, U.emitterY);
    d.y /= U.viewAspect;   // square-pixel local space

    // Wider, less elongated fireball footprint. W = belly width,
    // H = tail reach. Shorter H avoids the "candle stick" silhouette.
    const float W = 0.11;
    const float H = 0.22;
    float lx = d.x / W;
    float ly = d.y / H;

    // Tight bounding box — generous enough for tail sway + the longest
    // possible tail (loudest signal). Tightening too aggressively here
    // would chop the tip when the volume spikes.
    float tailMax = U.flameTailMax;
    if (abs(lx) > 2.4 || ly < -1.3 || ly > tailMax + 0.4) discard_fragment();

    float t = U.nowTime;

    // === Tail-only sway ===================================================
    // The base must stay rooted; only the upper portion should wobble.
    // tailWeight is 0 across the fireball belly (ly ≤ 0) and ramps in
    // smoothly through the tapered tail, peaking near the tip.
    float tailWeight = smoothstep(-0.15, 1.3, ly);

    // Multiple sines at incommensurate frequencies give the tail an
    // organic flicker without ever quite repeating.
    float wave1 = sin(t * 2.6 + ly * 1.8) * 0.32;
    float wave2 = sin(t * 4.3 - ly * 2.4 + 1.7) * 0.18;
    float wave3 = sin(t * 1.7 + ly * 3.6 - 0.6) * 0.12;
    float intrinsicSway = (wave1 + wave2 + wave3) * tailWeight;

    // External sway from CPU (pitch lean + velocity kick). Same height
    // weighting so the root stays anchored.
    float externalSway = U.flameSway * 8.0 * tailWeight;

    float elx = lx - (intrinsicSway + externalSway);

    // Per-side edge breathing — keeps the silhouette asymmetric and alive.
    float breathScale = tailWeight;
    float leftBreath  = 1.0 + sin(t * 2.9 + ly * 1.4) * 0.16 * breathScale;
    float rightBreath = 1.0 + sin(t * 3.4 + ly * 1.9 + 1.9) * 0.16 * breathScale;
    float widthMod = (elx < 0.0) ? leftBreath : rightBreath;

    // === Three nested layers — flat vector illustration ===================
    // Each inner layer is the same shape scaled down and lifted upward
    // so it reaches toward the tip rather than sharing the base.
    float outerW = fs_flame_profile(ly, tailMax) * widthMod;
    float outerSdf = abs(elx) - outerW;

    const float midScale = 0.72;
    float midW = fs_flame_profile((ly + 0.05) / midScale, tailMax) * midScale * widthMod;
    float midSdf = abs(elx) - midW;

    const float coreScale = 0.42;
    float coreW = fs_flame_profile((ly + 0.12) / coreScale, tailMax) * coreScale * widthMod;
    float coreSdf = abs(elx) - coreW;

    // Crisp vector edges — narrow AA only.
    const float AA = 0.020;
    float outerMask = smoothstep(AA, -AA, outerSdf);
    // Nest inner layers inside the outer silhouette so sway never lets
    // an inner color poke past the outline.
    float midMask = smoothstep(AA, -AA, midSdf) * outerMask;
    float coreMask = smoothstep(AA, -AA, coreSdf) * outerMask;

    // === Flat illustration palette ========================================
    float3 outerColor = float3(0.92, 0.38, 0.14);   // burnt orange
    float3 midColor   = float3(1.00, 0.70, 0.26);   // amber
    float3 coreColor  = float3(1.00, 0.96, 0.74);   // pale yellow

    // In-tune layered blues — saturated, not pastel. B pinned at 1.0, R
    // and G squeezed low so the cool tone reads even against the dark BG.
    float gT = U.pitchInTune * 0.75;
    outerColor = mix(outerColor, float3(0.02, 0.18, 1.00), gT);
    midColor   = mix(midColor,   float3(0.10, 0.42, 1.00), gT);
    coreColor  = mix(coreColor,  float3(0.45, 0.78, 1.00), gT);

    // Paint back-to-front. Outer fills the silhouette; mid and core
    // overwrite progressively smaller regions.
    float3 col = outerColor;
    col = mix(col, midColor,  midMask);
    col = mix(col, coreColor, coreMask);

    // Subtle volume pulse — opacity only, palette stays put. When the
    // user is scrubbing history the flame is no longer "live" so we mute
    // it to keep attention on the historical pitch dots.
    float pulse = 0.85 + 0.15 * U.emitterPulse;
    float scrubDim = 1.0 - 0.55 * U.scrubActive;
    float alpha = outerMask * pulse * scrubDim;
    return float4(col * alpha, alpha);
}

// --- Particles -------------------------------------------------------------

struct ParticleInstanceIn {
    float2 pos;
    float2 vel;
    float life;
    float seed;
};

struct ParticleVSOut {
    float4 position [[position]];
    float2 local;
    float life;
    float seed;
};

vertex ParticleVSOut vs_particle(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  constant ParticleInstanceIn* particles [[buffer(0)]],
                                  constant Uniforms& U [[buffer(1)]]) {
    ParticleInstanceIn p = particles[iid];

    // Aggressive ember shrink — visibly cools throughout its life:
    // life=1 ⇒ ~1.00, life=0.5 ⇒ ~0.46, life=0.1 ⇒ ~0.12.
    float lifeSize = 0.05 + 0.95 * pow(p.life, 1.10);
    // Per-particle size variation, wider range so the cloud feels organic.
    float sizeJitter = 0.55 + 0.85 * p.seed;
    float size = U.particleSize * lifeSize * sizeJitter;

    float2 corner;
    switch (vid) {
        case 0: corner = float2(-1, -1); break;
        case 1: corner = float2( 1, -1); break;
        case 2: corner = float2(-1,  1); break;
        case 3: corner = float2( 1,  1); break;
    }

    // Slight directional stretch along velocity so fast-moving sparks
    // streak — but kept subtle now that particles drift slowly.
    float speed = length(p.vel);
    float stretch = clamp(speed * 0.04, 0.0, 0.25);
    float2 offset = corner * float2(size, size * U.viewAspect * (1.0 + stretch));

    ParticleVSOut out;
    out.position = float4(p.pos + offset, 0, 1);
    out.local = corner;
    out.life = p.life;
    out.seed = p.seed;
    return out;
}

fragment float4 fs_particle_flame(ParticleVSOut in [[stage_in]],
                                   constant Uniforms& U [[buffer(0)]]) {
    float d2 = dot(in.local, in.local);
    if (d2 > 1.0) discard_fragment();
    // Soft round glow profile.
    float glow = pow(1.0 - d2, 2.0);

    // Color shifts from a warm cream when off-pitch to a clean green when
    // the player is locked in. Each particle picks up a tiny seed-based
    // warmth jitter so the cloud isn't perfectly uniform.
    float3 inTuneColor = float3(0.20, 0.55, 1.0);
    float3 offColor = float3(1.0, 0.74, 0.40);
    float3 base = mix(offColor, inTuneColor, U.pitchInTune);
    float warmJitter = 0.90 + 0.18 * in.seed;
    float3 col = base * warmJitter;

    // Strong ember cool-down — brightness keeps dropping the whole life,
    // not just at the tail. life=1 → 1.0, life=0.5 → 0.38, life=0.1 → 0.04.
    float ember = pow(in.life, 1.40);
    float tailFade = smoothstep(0.0, 0.12, in.life);
    // Per-particle brightness variation, wider range.
    float brightJitter = 0.55 + 0.70 * in.seed;
    float scrubDim = 1.0 - 0.55 * U.scrubActive;
    float alpha = glow * ember * tailFade * brightJitter * 0.70 * scrubDim;
    return float4(col * alpha, alpha);
}

// --- RMS volume bars (centered, scrolling with the spectrogram) ------------

fragment float4 fs_rmsbars(VSOut in [[stage_in]],
                            texture1d<float> rms [[texture(0)]],
                            constant Uniforms& U [[buffer(0)]]) {
    float timeNorm  = (U.isLandscape > 0.5) ? in.uv.x         : (1.0 - in.uv.y);
    float crossNorm = (U.isLandscape > 0.5) ? in.uv.y         : in.uv.x;

    // Ring-buffer time coordinate, matching fs_spectrogram exactly so the
    // scroll direction and speed track the heatmap underneath.
    float ringX = fract(U.writeHeadNorm
                        - (1.0 - timeNorm) * U.visibleRingFrac
                        - U.scrubOffsetNorm);

    // Discrete Voice-Memo style bars: quantize the ring time into slots and
    // leave a gap between slots so the result reads as a bar graph rather
    // than a continuous ribbon.
    const float barCount = 56.0;
    const float gap = 0.30;
    float slot = ringX * barCount;
    float frac = fract(slot);
    if (frac > 1.0 - gap) {
        return float4(0);
    }
    float barCenterRing = (floor(slot) + 0.5) / barCount;

    constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
    float rdb = rms.sample(s, barCenterRing).r;
    float n = saturate((rdb - U.rmsFloor) / max(1e-6, (U.rmsCeil - U.rmsFloor)));

    float halfWidth = n * U.rmsMaxHalfWidth;
    float dist = abs(crossNorm - 0.5);

    float aa = fwidth(dist) * 1.2;
    float core = smoothstep(halfWidth + aa, halfWidth - aa, dist);

    // Rounded pill ends: taper the alpha near each end of the slot in the
    // time direction so the bars read as soft capsules instead of hard rects.
    const float endRound = 0.18;
    float barT = frac / (1.0 - gap);           // 0..1 within the visible bar
    float endTaper = smoothstep(0.0, endRound, barT)
                   * smoothstep(1.0, 1.0 - endRound, barT);

    // Glass highlight: brighter near the center of the bar, fading to the
    // edge. The opacity is now a constant set by the user, independent of
    // the RMS value — only the *length* of the bar tracks volume.
    float distNorm = dist / max(1e-6, halfWidth);
    float highlight = pow(saturate(1.0 - distNorm), 2.0);
    float baseAlpha = core * endTaper * (0.45 + 0.55 * highlight);
    // Suppress the antialiased center sliver when the bar has effectively
    // zero length (silent / no data yet), so the dark top of the screen
    // does not show a faint vertical seam.
    float lengthGate = smoothstep(0.002, 0.012, halfWidth);
    return float4(1.0, 1.0, 1.0, baseAlpha * U.rmsOpacity * lengthGate);
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

// ---------------------------------------------------------------------------
// Particle simulation (compute) — drives ParticleInstanceIn in place.
// Mirrors the Swift ParticleSystem.step(dt:) logic exactly. RNG uses a
// per-(particle, frame) PCG hash so trajectories are deterministic per
// frame but never repeat.
// ---------------------------------------------------------------------------

struct SimUniforms {
    float dt;
    uint  frameCounter;
    uint  activeCount;
    uint  capacity;
    float emitterX;
    float emitterY;
    float cameraSemitone;
    float semitoneSpacing;
    float upwardBias;
    float brownian;       // pitch-scaled on CPU
    float attract;        // pitch-scaled on CPU
    float boost;          // pitch-scaled on CPU (0 when no pitch)
    float boostRadius;
    float globalGravity;
    float lifeDecay;
    float damp;             // 1 - min(1, 0.30 * dt)
    float emitterIntensity; // 0..1 loudness — scales initial spawn speed
};

static inline uint pcg_hash(uint state) {
    state = state * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static inline float pcg_rand01(thread uint& state) {
    state = pcg_hash(state);
    return float(state) / 4294967295.0;
}

kernel void simulate_particles(device ParticleInstanceIn* particles [[buffer(0)]],
                                constant SimUniforms& U             [[buffer(1)]],
                                uint gid                              [[thread_position_in_grid]]) {
    if (gid >= U.capacity) return;
    ParticleInstanceIn p = particles[gid];
    // PCG seed combines particle id and frame counter so each particle
    // gets a fresh stream every frame.
    uint rng = pcg_hash(gid * 2654435761u + U.frameCounter * 19349663u + 17u);

    p.life -= U.dt * U.lifeDecay;
    if (p.life <= 0.0) {
        if (gid < U.activeCount) {
            // Respawn — fully omnidirectional spawn, and the initial
            // speed scales with the loudness envelope. Quiet ≈ baseline,
            // loud bursts up to 3× as fast so peaks feel like sparks
            // shooting outward.
            float angle = pcg_rand01(rng) * 2.0 * 3.14159265;
            float speedRand = pcg_rand01(rng);
            float baseSpeed = 0.02 + pow(speedRand, 1.3) * 0.50;
            float volMul = 1.0 + 2.0 * saturate(U.emitterIntensity);
            float speed = baseSpeed * volMul;
            p.pos = float2(U.emitterX + (pcg_rand01(rng) - 0.5) * 0.045,
                           U.emitterY + (pcg_rand01(rng) - 0.5) * 0.020);
            p.vel = float2(cos(angle) * speed, sin(angle) * speed);
            p.life = 1.0;
            p.seed = pcg_rand01(rng);
        } else {
            // Volume-throttled: keep this slot dead so the visible count
            // matches the loudness envelope.
            p.life = 0.0;
        }
        particles[gid] = p;
        return;
    }

    float mass    = 0.6 + p.seed * 1.4;
    float invMass = 1.0 / mass;

    // Spring toward nearest reference line.
    float kf    = p.pos.x / U.semitoneSpacing + U.cameraSemitone;
    float k     = round(kf);
    float lineX = (k - U.cameraSemitone) * U.semitoneSpacing;
    float dx    = p.pos.x - lineX;
    float absDx = fabs(dx);

    p.vel.x -= U.attract * dx * U.dt * invMass;
    if (absDx < U.boostRadius) {
        float near = 1.0 - absDx / U.boostRadius;
        p.vel.y += U.boost * near * U.dt * invMass;
    }
    p.vel.y += U.upwardBias * U.dt * invMass;
    p.vel.y -= U.globalGravity * U.dt;

    float brownianScale = sqrt(invMass);
    p.vel.x += (pcg_rand01(rng) - 0.5) * U.brownian * U.dt * brownianScale;
    p.vel.y += (pcg_rand01(rng) - 0.5) * U.brownian * U.dt * brownianScale;

    p.vel *= U.damp;
    p.pos += p.vel * U.dt;

    particles[gid] = p;
}

//LibraryACESOutputTransform.hlsl

#ifndef LIBRARY_ACES_OUTPUT_TRANSFORM
//[NO CONFIG]
#define LIBRARY_ACES_OUTPUT_TRANSFORM

//ACES 1.x Reference Gamut Compression + Reference Rendering Transform + parametric Output Display Transform
//(the "single stage tone scale" used by the ACES HDR output transforms). Unlike the fitted ACES curves in
//LibraryTonemaps.hlsl this one can target any peak luminance, which is what the HDR peak extension in
//PixelShaderPass_PostProcessFinal.hlsl needs.
//
//Ported from RenoDX - https://github.com/clshortfuse/renodx
//  src/shaders/tonemap/aces.hlsl (RGCAndRRTAndODT and everything it calls)
//  src/shaders/tonemap.hlsl      (config::ApplyACES)
//RenoDX is MIT licensed, Copyright (C) Carlos Lopez. Its port follows the Academy's aces-dev reference.
//Only what the peak extension uses is kept, and everything is prefixed AcesOT_ so nothing collides with
//the ACES helpers already in LibraryTonemaps.hlsl / PixelShaderPass_PostProcessFinal.hlsl.

#include "LibraryMath.hlsl"

//|||||||||||||||||||||||||||||||||| COLOR SPACES ||||||||||||||||||||||||||||||||||

static const float3x3 AcesOT_BT709ToAP1 = float3x3(
    0.6130974024, 0.3395231462, 0.0473794514,
    0.0701937225, 0.9163538791, 0.0134523985,
    0.0206155929, 0.1095697729, 0.8698146342);

//XYZ_TO_AP0 * AP1_TO_XYZ, same matrices RenoDX multiplies together
static const float3x3 AcesOT_AP1ToAP0 = float3x3(
     0.6954522413, 0.1406786965, 0.1638690622,
     0.0447945634, 0.8596711184, 0.0955343182,
    -0.0055258826, 0.0040252103, 1.0015006722);

//XYZ_TO_AP1 * AP0_TO_XYZ
static const float3x3 AcesOT_AP0ToAP1 = float3x3(
     1.4514393161, -0.2365107469, -0.2149285693,
    -0.0765537733,  1.1762296998, -0.0996759264,
     0.0083161484, -0.0060324498,  0.9977163014);

//with Bradford adaptation D60 -> D65
static const float3x3 AcesOT_AP1ToBT709 = float3x3(
     1.7050509927, -0.6217921207, -0.0832588720,
    -0.1302564175,  1.1408047366, -0.0105483191,
    -0.0240033568, -0.1289689761,  1.1529723329);

//luminance row of AP1_TO_XYZ
static const float3 AcesOT_AP1Luminance = float3(0.2722287168, 0.6740817658, 0.0536895174);

//|||||||||||||||||||||||||||||||||| RRT ||||||||||||||||||||||||||||||||||

float AcesOT_Rgb2Yc(float3 rgb)
{
    const float ycRadiusWeight = 1.75;

    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    //never negative in exact math, but rounding on near-neutral colors can dip below zero and sqrt would make a NaN
    float chroma = sqrt(max(b * (b - g) + g * (g - r) + r * (r - b), 0.0));

    return (b + g + r + ycRadiusWeight * chroma) / 3.0;
}

float AcesOT_Rgb2Saturation(float3 rgb)
{
    float minrgb = min(min(rgb.r, rgb.g), rgb.b);
    float maxrgb = max(max(rgb.r, rgb.g), rgb.b);
    return (max(maxrgb, 1e-10) - max(minrgb, 1e-10)) / max(maxrgb, 1e-2);
}

//sigmoid function in the range 0 to 1 spanning -2 to +2
float AcesOT_SigmoidShaper(float x)
{
    float t = max(1.0 - abs(0.5 * x), 0.0);
    float y = 1.0 + sign(x) * (1.0 - t * t);
    return 0.5 * y;
}

float AcesOT_GlowFwd(float ycIn, float glowGainIn, float glowMid)
{
    if (ycIn <= 2.0 / 3.0 * glowMid)
        return glowGainIn;
    else if (ycIn >= 2.0 * glowMid)
        return 0.0;
    else
        return glowGainIn * (glowMid / ycIn - 0.5);
}

//geometric hue angle in degrees (0-360)
float AcesOT_Rgb2Hue(float3 rgb)
{
    float hue;

    if (rgb.r == rgb.g && rgb.g == rgb.b)
        hue = 0.0; //neutral colors have an undefined hue
    else
        hue = (180.0 / MATH_PI) * atan2(sqrt(3.0) * (rgb.g - rgb.b), 2.0 * rgb.r - rgb.g - rgb.b);

    if (hue < 0.0)
        hue = hue + 360.0;

    return clamp(hue, 0.0, 360.0);
}

float AcesOT_CenterHue(float hue, float centerHue)
{
    float hueCentered = hue - centerHue;

    if (hueCentered < -180.0)
        hueCentered += 360.0;
    else if (hueCentered > 180.0)
        hueCentered -= 360.0;

    return hueCentered;
}

//input is ACES AP0, output is AP1 (the rendering space the ODT works in)
float3 AcesOT_RRT(float3 aces)
{
    //glow module
    const float glowGain = 0.05;
    const float glowMid = 0.08;
    float saturation = AcesOT_Rgb2Saturation(aces);
    float ycIn = AcesOT_Rgb2Yc(aces);
    float s = AcesOT_SigmoidShaper((saturation - 0.4) / 0.2);
    float addedGlow = 1.0 + AcesOT_GlowFwd(ycIn, glowGain * s, glowMid);
    aces *= addedGlow;

    //red modifier
    const float redScale = 0.82;
    const float redPivot = 0.03;
    const float redHue = 0.0;
    const float redWidth = 135.0;
    float hue = AcesOT_Rgb2Hue(aces);
    float centeredHue = AcesOT_CenterHue(hue, redHue);
    float hueWeight = smoothstep(0.0, 1.0, 1.0 - abs(2.0 * centeredHue / redWidth));
    hueWeight *= hueWeight;

    aces.r += hueWeight * saturation * (redPivot - aces.r) * (1.0 - redScale);

    //ACES to RGB rendering space
    aces = clamp(aces, 0.0, 65535.0);
    float3 rgbPre = mul(AcesOT_AP0ToAP1, aces);
    rgbPre = clamp(rgbPre, 0.0, 65504.0);

    //global desaturation
    const float rrtSatFactor = 0.96;
    rgbPre = lerp(dot(rgbPre, AcesOT_AP1Luminance).xxx, rgbPre, rrtSatFactor);

    return rgbPre;
}

//|||||||||||||||||||||||||||||||||| REFERENCE GAMUT COMPRESSION ||||||||||||||||||||||||||||||||||

float AcesOT_GamutCompressChannel(float dist, float lim, float thr, float pwr)
{
    if (dist < thr)
        return dist; //no compression below threshold

    //scale factor for y = 1 intersect
    float scl = (lim - thr) / pow(pow((1.0 - thr) / (lim - thr), -pwr) - 1.0, 1.0 / pwr);

    //normalize distance outside threshold by scale factor
    float nd = (dist - thr) / scl;
    float p = pow(nd, pwr);

    return thr + scl * nd / (pow(1.0 + p, 1.0 / pwr));
}

float3 AcesOT_GamutCompress(float3 linearAP1)
{
    //achromatic axis
    float ach = max(linearAP1.r, max(linearAP1.g, linearAP1.b));
    float absAch = abs(ach);

    //distance from the achromatic axis for each color component aka inverse RGB ratios
    float3 dist = ach != 0.0 ? (ach - linearAP1) / absAch : 0.0.xxx;

    float3 compressedDist = float3(
        AcesOT_GamutCompressChannel(dist.r, 1.147, 0.815, 1.2),  //cyan
        AcesOT_GamutCompressChannel(dist.g, 1.264, 0.803, 1.2),  //magenta
        AcesOT_GamutCompressChannel(dist.b, 1.312, 0.880, 1.2)); //yellow

    return ach - compressedDist * absAch;
}

//|||||||||||||||||||||||||||||||||| ODT (SINGLE STAGE TONE SCALE) ||||||||||||||||||||||||||||||||||

static const float3x3 AcesOT_SplineM = float3x3(
     0.5, -1.0, 0.5,
    -1.0,  1.0, 0.0,
     0.5,  0.5, 0.0);

//(log10 luminance, stops) pairs: log10(0.0001) = -4, log10(0.02), log10(48), log10(10000) = 4
static const float2x2 AcesOT_MinLumTable = float2x2(
    -4.0, -15.0,
    -1.6989700043, -6.5);

static const float2x2 AcesOT_MaxLumTable = float2x2(
    1.6812412374, 6.5,
    4.0, 18.0);

static const float2x2 AcesOT_BendsLowTable = float2x2(
    -15.0, 0.18,
    -6.5, 0.35);

static const float2x2 AcesOT_BendsHighTable = float2x2(
    6.5, 0.89,
    18.0, 0.90);

float AcesOT_Interpolate1D(float2x2 table, float p)
{
    if (p < table[0].x)
        return table[0].y;
    else if (p >= table[1].x)
        return table[1].y;

    float s = (p - table[0].x) / (table[1].x - table[0].x);
    return table[0].y * (1.0 - s) + table[1].y * s;
}

struct AcesOT_ODTConfig
{
    float3 minPoint;
    float3 midPoint;
    float3 maxPoint;
    float coefsLow[6];
    float coefsHigh[6];
};

AcesOT_ODTConfig AcesOT_CreateODTConfig(float minLuminance, float maxLuminance)
{
    AcesOT_ODTConfig config;

    float minLuminanceLog10 = log10(minLuminance);
    float maxLuminanceLog10 = log10(maxLuminance);
    float acesMin = 0.18 * exp2(AcesOT_Interpolate1D(AcesOT_MinLumTable, minLuminanceLog10));
    float acesMax = 0.18 * exp2(AcesOT_Interpolate1D(AcesOT_MaxLumTable, maxLuminanceLog10));

    //mid point: scene 0.18 -> 4.8 nits (of a 48 nit reference), slope 1.55
    const float3 midPt = float3(0.18, 4.8, 1.55);

    float2 logMin = float2(log10(acesMin), minLuminanceLog10);
    float2 logMid = float2(log10(midPt.x), log10(midPt.y));
    float2 logMax = float2(log10(acesMax), maxLuminanceLog10);

    //low half: flat below the min point, bend interpolated from the table
    float knotIncLow = (logMid.x - logMin.x) / 3.0;
    config.coefsLow[0] = logMin.y;
    config.coefsLow[1] = config.coefsLow[0];
    config.coefsLow[3] = (midPt.z * (logMid.x - 0.5 * knotIncLow)) + (logMid.y - midPt.z * logMid.x);
    config.coefsLow[4] = (midPt.z * (logMid.x + 0.5 * knotIncLow)) + (logMid.y - midPt.z * logMid.x);
    config.coefsLow[5] = config.coefsLow[4];
    float pctLow = AcesOT_Interpolate1D(AcesOT_BendsLowTable, log2(acesMin / 0.18));
    config.coefsLow[2] = logMin.y + pctLow * (logMid.y - logMin.y);

    //high half: flat above the max point (this is where the peak luminance lives)
    float minCoef = logMid.y - midPt.z * logMid.x;
    float knotIncHigh = (logMax.x - logMid.x) / 3.0;
    config.coefsHigh[0] = (midPt.z * (logMid.x - 0.5 * knotIncHigh)) + minCoef;
    config.coefsHigh[1] = (midPt.z * (logMid.x + 0.5 * knotIncHigh)) + minCoef;
    config.coefsHigh[3] = logMax.y;
    config.coefsHigh[4] = config.coefsHigh[3];
    config.coefsHigh[5] = config.coefsHigh[4];
    float pctHigh = AcesOT_Interpolate1D(AcesOT_BendsHighTable, log2(acesMax / 0.18));
    config.coefsHigh[2] = logMid.y + pctHigh * (logMax.y - logMid.y);

    config.minPoint = float3(logMin.x, logMin.y, 0.0);
    config.midPoint = float3(logMid.x, logMid.y, midPt.z);
    config.maxPoint = float3(logMax.x, logMax.y, 0.0);

    return config;
}

float AcesOT_SSTS(float x, AcesOT_ODTConfig config)
{
    const int knotsLow = 4;
    const int knotsHigh = 4;

    float logX = log10(max(x, MATH_FLT_MIN));
    float logY;

    if (logX > config.maxPoint.x)
    {
        //above max breakpoint (overshoot), flat extension
        logY = config.maxPoint.y;
    }
    else if (logX >= config.midPoint.x)
    {
        float knotCoord = (knotsHigh - 1) * (logX - config.midPoint.x) / (config.maxPoint.x - config.midPoint.x);
        int j = (int)knotCoord;
        float t = knotCoord - j;

        float3 cf = float3(config.coefsHigh[j], config.coefsHigh[j + 1], config.coefsHigh[j + 2]);
        float3 monomials = float3(t * t, t, 1.0);
        logY = dot(monomials, mul(AcesOT_SplineM, cf));
    }
    else if (logX > config.minPoint.x)
    {
        float knotCoord = (knotsLow - 1) * (logX - config.minPoint.x) / (config.midPoint.x - config.minPoint.x);
        int j = (int)knotCoord;
        float t = knotCoord - j;

        float3 cf = float3(config.coefsLow[j], config.coefsLow[j + 1], config.coefsLow[j + 2]);
        float3 monomials = float3(t * t, t, 1.0);
        logY = dot(monomials, mul(AcesOT_SplineM, cf));
    }
    else
    {
        //below min breakpoint (undershoot), flat extension
        logY = config.minPoint.y;
    }

    return pow(10.0, logY);
}

//first half of RenoDX's RGCAndRRTAndODT: scene linear BT.709 in, the RRT's AP1 rendering space out.
//Split from the ODT so two output transforms that only differ in peak can share it.
float3 AcesOT_RGCAndRRT(float3 color)
{
    color = mul(AcesOT_BT709ToAP1, color);
    color = AcesOT_GamutCompress(color);
    color = mul(AcesOT_AP1ToAP0, color);
    return AcesOT_RRT(color);
}

//the ODT tone scale sends every AP1 channel below this through the lower spline, whose shape depends only on the
//minimum luminance - so below it, two ODTs with the same minimum but different peaks return identical values
static const float AcesOT_ToneScaleMidPoint = 0.18;

//with non-negative BT.709 input, no AP1 channel coming out of AcesOT_RGCAndRRT can exceed max(input) * 1.532:
//BT709->AP1 and the gamut compression never raise the largest channel, AP1->AP0 raises it by at most 1.0055,
//the glow by at most 1.05, the red modifier only pulls toward 0.03, AP0->AP1 by at most 1.4514 (its largest
//positive row sum), and the final desaturation stays between luminance and the channel. So an input below
//AcesOT_ToneScaleMidPoint / 1.532 = 0.1175 is guaranteed to stay on the lower spline. 0.11 keeps a margin.
static const float AcesOT_SceneBelowMidPoint = 0.11;

//second half of RenoDX's RGCAndRRTAndODT, plus config::ApplyACES's scaling with gamma correction off.
//out is display linear BT.709 where 1.0 = gameNits, peaking at peakNits / gameNits.
//midGray is where scene 0.18 should land in that output - pinning it lets two calls that only differ in
//peakNits agree everywhere except the highlights.
float3 AcesOT_ODTFromRRT(float3 rgbPre, float midGray, float peakNits, float gameNits)
{
    const float acesMidGray = 0.10;
    const float acesMinNits = 0.0001;
    float midGrayScale = midGray / acesMidGray;

    float acesMin = (acesMinNits / gameNits) / midGrayScale;
    float acesMax = (peakNits / gameNits) / midGrayScale;

    AcesOT_ODTConfig config = AcesOT_CreateODTConfig(acesMin * 48.0, acesMax * 48.0);
    float3 tonescaled = clamp(float3(
        AcesOT_SSTS(rgbPre.r, config),
        AcesOT_SSTS(rgbPre.g, config),
        AcesOT_SSTS(rgbPre.b, config)), 0.0, 65535.0);

    return mul(AcesOT_AP1ToBT709, tonescaled) / 48.0 * midGrayScale;
}

//RenoDX's config::ApplyACES with gamma correction off, in one call
float3 AcesOT_Tonemap(float3 untonemappedBT709, float midGray, float peakNits, float gameNits)
{
    return AcesOT_ODTFromRRT(AcesOT_RGCAndRRT(untonemappedBT709), midGray, peakNits, gameNits);
}

#endif

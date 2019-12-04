///@file   ssr-ps.hlsl
///@author Chris Newman
///@brief  Shader that performs screen-space ray tracing to generate
///        reflections for smooth surfaces.

  // Contains constants such as pi and epsilon
#include "constants.hlsli"
  // Contains values regarding the viewport, such as viewport dimensions.
  // contains the `screen_pos_to_texel2` function.
#include "screen-space.hlsli"
  // Contains view (+viewInv) and projection matricies, along with frustum data
  // such as farPlaneZ.
#include "view-proj.hlsli"

  // Number of samples the ray is divided into
static const uint maxIterations = 100;
  // Maximum distance a ray travels from its source.
static const float maxDistance = 100;
  // How "thick" each pixel is in viewspace.
static const float thickness = 2;
  // Surfaces with roughness above this value do not have reflections
  // calculated for them.
static const float maxRoughness = 0.5;
  // When to begin fading out near the edge of the screen.
static const float edgeFadeDist = 0.2;

  // Arbitrary value to scale kernel size by.
static const float blurRoughnessMultiplier = 100;
  // Value determining how far a ray needs to travel to hit maximum diffusion.
static const float blurDist = 10;
  // All samples taken need to be within this range of the ray hit in depth.
static const float blurRange = 4;

  // Randomly generated sampling kernel for blurry reflections.
static const uint kernelSize = 16;
cbuffer kernel : register(b10)
{
  float4 kernel[kernelSize];
}

  // Output from vertex shader.
struct VSOut
{
  float4 pos : SV_POSITION;
  float2 tex : TEXCOORD0;
};

  // Basic sampler state
SamplerState smp : register(s0);

  // Surface albedo values / Fresnel response for metallic surfaces.
Texture2D albedoTex    : register(t0);
  // How metallic / dialectric a surface is.
Texture2D metallicTex  : register(t1);
  // How "rough" a surface is.
Texture2D roughnessTex : register(t2);
  // Per-fragment normal vector. Alpha channel contains linear scene depth as 
  // a fraction of the far plane's Z.
Texture2D normalTex    : register(t3);
  // Viewspace position of a fragment. Should be reconstructed instead of 
  // sampled in the future.
Texture2D posTex       : register(t4);
  // Calculated lighting data for the scene
Texture2D lightTex     : register(t5);

  // Skybox texture, used as fallback if the ray hits nothing.
TextureCube skyTex     : register(t9);

  // Function for translating a viewspace position into a texture coordinate.
float2 get_sample_coord(float3 pos, float2 jitterVal)
{
    // Get texture-space coordinate.
  float2 coord = (pos.xy + 1) / 2;
  coord.y = 1 - coord.y;
  
    // Need to account for resolution scaling when sampling.
  coord.x *= screenScaleX;
  coord.y *= screenScaleY;

    // Jitter looks kinda bad, taking it out for now.
  return coord;// +jitterVal;
}

  // Squared distance between two points.
float dist_squared(float3 p1, float3 p2)
{
  p2 -= p1;
  return abs(dot(p2, p2));
}

  // Performs fading for samples taken along the edge of the screen.
void edge_fading(float2 sampCoord, inout float falloff)
{
    // Fade left edge
  if (sampCoord.x < edgeFadeDist)
  {
    falloff = lerp(0, falloff, 
      sampCoord.x / edgeFadeDist
    );
  }
    // Fade right edge
  else if (sampCoord.x > 1 - edgeFadeDist)
  {
    falloff = lerp(falloff, 0, 
      (sampCoord.x - (1 - edgeFadeDist)) / edgeFadeDist
    );
  }

    // Fade bottom edge
  if (sampCoord.y < edgeFadeDist)
  {
    falloff = lerp(0, falloff, 
      sampCoord.y / edgeFadeDist
    );
  }
    // Fade top edge
  else if (sampCoord.y > 1 - edgeFadeDist)
  {
    falloff = lerp(falloff, 0, 
      (sampCoord.y - (1 - edgeFadeDist)) / edgeFadeDist
    );
  }
}

  // Shader program entry point
float4 main(VSOut pin) : SV_TARGET0
{
    // Translate screen coordinates into texture UV coordinates.
  float2 coords = screen_pos_to_texel2(pin.pos.xy);

    // If the fragment is empty, return the existing color
  if (posTex.Sample(smp, coords).w < epsilon)
    return lightTex.Sample(smp, coords);

    // Get screen tex size
  uint w = 1, h = 1, mips = 1;
  lightTex.GetDimensions(0, w, h, mips);

    // Sample textures
  float4 normSamp = normalTex.Sample(smp, coords);
  float4 position = posTex.Sample(smp, coords).rgbr;
  position.w = 1;
  float4 color    = lightTex.Sample(smp, coords);
  float roughness = roughnessTex.Sample(smp, coords).r;
  float metallic  = metallicTex.Sample(smp, coords).r;
  float3 albedo   = albedoTex.Sample(smp, coords).rgb;

    // Value used to jitter sample position. Currently unused
  float2 jitter = float2(0, 0);
  jitter.y = float(int(pin.pos.x + pin.pos.y) & 1) * 4 * (1.f / h);

    // Don't calculate reflections for rough surfaces.
  if (roughness > maxRoughness)
  {
    return float4(color.rgb, 1);
  }
  
    // Metallic surfaces should have tinted reflections.
  float4 outColor = float4(lerp(1 - roughness, albedo, metallic), 1);

    // Calculate value to reduce reflection intensity by based on roughness
    // value of the surface.
  float roughnessFalloff = (1 - roughness / maxRoughness);
    // Squared roughnessFalloff looks a bit better.
  roughnessFalloff *= roughnessFalloff;

    // Get normal
  float4 normal = normalize(normSamp.rgb).rgbr;
  normal.w = 0;

    // Offset the initial position to reduce self-intersection issues.
  position += normal * 0.1f;


    // Calculate ray direction
  float4 incoming = normalize(position.rgb).rgbr;
  incoming.w = 0;
  float4 rayDir   = normalize(reflect(incoming, normal)).rgbr;
  rayDir.w = 0;

    // Find ray begin / end
  float4 initPos = position;
  float4 endPoint = initPos + rayDir * maxDistance;
  // TODO: Clip ray

    // Ray's viewspace Z begin / end
  float initZ = initPos.z;
  float endZ = endPoint.z;

    // Project the ray's position into clip space
  position = mul(proj, position);
  initPos = position;
  endPoint = mul(proj, endPoint);

    // How far to scale the kernel samples. Based on ray distance and 
    // surface roughness.
  float blurRadius =
    (roughness / maxRoughness) *
    blurRoughnessMultiplier;

    // Get blurred skybox sample
  uint cw = 0, ch = 0, cmips = 0;
  skyTex.GetDimensions(0, cw, ch, cmips);
  float4 skyboxColor = skyTex.SampleLevel(smp, mul(viewInv, rayDir), (1 - roughnessFalloff) * cmips * 0.5);
  skyboxColor *= roughnessFalloff;
  skyboxColor *= outColor;

    // ray march
  [loop] for (uint iteration = 0; iteration < maxIterations; ++iteration)
  {
      // Move the ray forward.
    position = lerp(initPos, endPoint, float(iteration) / float(maxIterations));
    float currentZ = lerp(initZ, endZ, float(iteration) / float(maxIterations));
  
      // Check if the ray has gone beyond the viewport.
    if (position.z < 0 || position.z > position.w)
    {
      return float4(color.rgb, 1) + skyboxColor;
    }
    
      // Retrieve texture-space coordinates of the ray's location.
    position /= position.w;
    float2 sampCoord = get_sample_coord(position, jitter);

      // Exit if we're outside the screen.
    if (any(sampCoord > 1) || any(sampCoord < 0))
    {
      return float4(color.rgb, 1) + skyboxColor;
    }

      // Test for a hit. If the ray's depth is between the sampled depth and a
      // thickness value, report it as a hit.
      // Normal texture contains linear scene depth in its alpha channel.
    float pixelDepth = 
      normalTex.Load(int3(sampCoord * float2(w, h), 0)).a * farPlaneZ;

    if (pixelDepth > currentZ && pixelDepth - thickness < currentZ)
    {
        // We hit something!

        // Check hit normal, if it's facing the same direction as the ray dir,
        // we hit the back face and need to discard this sample.
      float3 hitNorm = normalize(normalTex.Load(int3(sampCoord * float2(w, h), 0)).rgb);
      if (dot(hitNorm, rayDir) > 0)
      {
        return float4(color.rgb, 1) + skyboxColor;
      }

        // Distance falloff
      float falloff = (1 - (float)iteration / (float)maxIterations);

        // edge fade
      edge_fading(sampCoord, falloff);

        // thickness fade. Grazing hits are likely to appear distorted, so 
        // fade them out. It's up for debate as to if this looks good or not.
      //falloff = lerp(0, falloff, 
      //  (currentZ - (pixelDepth - thickness)) / thickness
      //);

        // Final sample color
      float4 sampledColor = 0;

        // Iterate over the kernel, gather samples
      [unroll] for (uint i = 0; i < kernelSize; ++i)
      {
          // Location to sample at
        float2 currentSampLoc = 
          sampCoord + 
          kernel[i].xy * float2(1 / (float)w, 1 / (float)h) * 
          blurRadius;

          // Sampled Color
        float4 currentSamp =
          float4(lightTex.Load(int3(currentSampLoc * float2(w, h), 0)).rgb, 1);
          // Sampled depth value
        float currentSampDepth = 
          normalTex.Load(int3(currentSampLoc * float2(w, h), 0)).a * farPlaneZ;
        
          // Make sure this sample is near the ray hit.
        float rangeCheck = 
          (abs(pixelDepth - currentSampDepth) < blurRange) ? 1.f : 0.f;

          // If it is, add it to the output color
        sampledColor += currentSamp * rangeCheck;
        sampledColor += skyboxColor * (1 - rangeCheck);
      }
      sampledColor /= kernelSize;

        // Final color
      return float4(color.rgb, 1) + outColor * sampledColor * falloff * roughnessFalloff + skyboxColor * (1 - falloff);
    }
  }

    // Return base color if the ray traveled its full distance but hit nothing.
  //return float4(1, 0, 0, 1);
  return float4(color.rgb, 1) + skyboxColor;
}


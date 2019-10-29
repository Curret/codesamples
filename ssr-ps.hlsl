///@file   ssr-ps.hlsl
///@author Chris Newman
///@brief  Shader that performs screen-space ray tracing to generate
///        reflections for smooth surfaces.

  // Contains constants such as pi and epsilon
#include "constants.hlsli"
  // Contains values regarding the viewport, such as viewport dimensions.
  // contains the `screen_pos_to_texel2` function.
#include "screen-space.hlsli"
  // Contains view and projection matricies, along with frustum data such as 
  // farPlaneZ.
#include "view-proj.hlsli"

  // Maximum number of samples to take during ray march.
static const uint maxIterations = 100;
  // How far in view space to travel between samples.
static const float stride = 0.3;
  // Farthest away the ray can be from the viewpoint without being cut off.
  // Value is negative, as -Z is forward.
static const float maxZ = -500;
  // How "thick" each pixel is in viewspace.
static const float thickness = 0.7;
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

  // Calculated lighting data for the scene
Texture2D lightTex     : register(t0);
  // Surface albedo values / Fresnel response for metallic surfaces.
Texture2D albedoTex    : register(t1);
  // How metallic / dialectric a surface is.
Texture2D metallicTex  : register(t2);
  // How "rough" a surface is.
Texture2D roughnessTex : register(t3);
  // Per-fragment normal vector. Alpha channel contains linear scene depth as 
  // a fraction of the far plane's Z.
Texture2D normalTex    : register(t4);
  // Viewspace position of a fragment. Should be reconstructed instead of 
  // sampled in the future.
Texture2D posTex       : register(t5);

  // Function for translating a viewspace position into a texture coordinate.
float2 get_sample_coord(float3 pos)
{
    // Perform translation into NDC.
  float4 position = float4(pos, 1);
  position = mul(proj, position);
  position /= position.w;

    // Get texture-space coordinate.
  float2 coord = (position.xy + 1) / 2;
  coord.y = 1 - coord.y;

    // Need to account for resolution scaling when sampling.
  coord.x *= screenScaleX;
  coord.y *= screenScaleY;

  return coord;
}

  // Squared distance between two points.
float dist_squared(float3 p1, float3 p2)
{
  float3 p = p2 - p1;
  return abs(dot(p, p));
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

    // If the fragment is empty, don't do anything.
  if (posTex.Sample(smp, coords).w < epsilon)
    discard;

    // Get tex size
  uint w = 1, h = 1, mips = 1;
  lightTex.GetDimensions(0, w, h, mips);

    // Sample textures
  float4 normSamp = normalTex.Sample(smp, coords);
  float3 position = posTex.Sample(smp, coords).rgb;
  float4 color    = lightTex.Sample(smp, coords);
  float roughness = roughnessTex.Sample(smp, coords).r;
  float metallic  = metallicTex.Sample(smp, coords).r;
  float3 albedo   = albedoTex.Sample(smp, coords).rgb;

  float3 initPos = position;

    // Don't calculate reflections for rough surfaces.
  if (roughness > maxRoughness)
  {
    return float4(color.rgb, 1);
  }
  
    // Metallic surfaces should have tinted reflections.
  float4 outColor = float4(lerp(1 - roughness, albedo, metallic), 1);

    // Get normal
  float3 normal = normalize(normSamp.rgb);


    // Calculate ray direction
  float3 incoming = normalize(position);
  float3 rayDir   = normalize(reflect(incoming, normal));


    // ray march
  [loop] for (uint iteration = 0; iteration < maxIterations; ++iteration)
  {
      // Move the ray forward.
    position += rayDir * stride;
  
      // Check if the ray has gone behind the viewpoint.
    if (position.z > 0)
    {
      // exit, no hit
      return float4(color.rgb, 1);
    }
  
      // Check if the ray has traveled too far from the viewpoint.
    if (position.z < maxZ)
    {
      // exit, no hit
      return float4(color.rgb, 1);
    }
    
      // Retrieve texture-space coordinates of the ray's location.
    float2 sampCoord = get_sample_coord(position);

      // Exit if we're outside the screen.
    if (any(sampCoord > 1) || any(sampCoord < 0))
    {
      return float4(color.rgb, 1);
    }

      // Test for a hit. If the ray's depth is between the sampled depth and a
      // thickness value, report it as a hit.
      // Normal texture contains linear scene depth in its alpha channel.
    float pixelDepth = 
      normalTex.Sample(smp, get_sample_coord(position)).a * farPlaneZ;

    if (pixelDepth > position.z && pixelDepth - thickness < position.z)
    {
        // We hit something!

        // Check hit normal, if it's facing the same direction as the ray dir,
        // we hit the back face and need to discard this sample.
      float3 hitNorm = normalize(normalTex.Sample(smp, sampCoord).rgb);
      if (dot(hitNorm, rayDir) > 0)
      {
        return float4(color.rgb, 1);
      }

        // Distance falloff
      float falloff = (1 - (float)iteration / (float)maxIterations);

        // edge fade
      edge_fading(sampCoord, falloff);

        // thickness fade. Grazing hits are likely to appear distorted, so 
        // fade them out.
      falloff = lerp(0, falloff, 
        (position.z - (pixelDepth - thickness)) / thickness
      );

        // Roughness fade
      falloff = falloff * (1- roughness / maxRoughness);
      
        // How far to scale the kernel samples. Based on ray distance and 
        // surface roughness.
      float blurRadius = 
        (dist_squared(position, initPos) / (blurDist*blurDist)) * 
        (roughness / maxRoughness) * 
        blurRoughnessMultiplier;

        // Final sample color
      float4 sampledColor = 0;

        // Iterate over the kernel, gather samples
      [unroll] for (uint i = 0; i < kernelSize; ++i)
      {
          // Location to sample at
        float2 currentSampLoc = 
          sampCoord + 
          kernel[i] * float2(1 / (float)w, 1 / (float)h) * 
          blurRadius;

          // Sampled Color
        float4 currentSamp =
          float4(lightTex.Sample(smp, currentSampLoc).rgb, 1);
          // Sampled depth value
        float currentSampDepth = 
          normalTex.Sample(smp, currentSampLoc).a * farPlaneZ;
        
          // Make sure this sample is near the ray hit.
        float rangeCheck = 
          (abs(pixelDepth - currentSampDepth) < blurRange) ? 1.f : 0.f;

          // If it is, add it to the output color
        sampledColor += currentSamp * rangeCheck;
      }
      sampledColor /= kernelSize;

        // Final color
      return float4(color.rgb, 1) + outColor * sampledColor * falloff;
    }
  }

    // Return base color if the ray traveled its full distance but hit nothing.
  return float4(color.rgb, 1);
}


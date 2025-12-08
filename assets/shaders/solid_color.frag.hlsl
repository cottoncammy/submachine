Texture2D<float4> Texture : register(t0, space2);
SamplerState Sampler : register(s0, space2);

float4 main(float4 vColor : TEXCOORD0, float2 vTexCoord : TEXCOORD1) : SV_Target0 {
    return Texture.Sample(Sampler, vTexCoord) * vColor;
}

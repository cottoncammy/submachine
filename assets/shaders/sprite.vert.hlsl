cbuffer uniforms : register(b0, space1) {
    column_major float4x4 uView;
    column_major float4x4 uProj;
}

struct SpriteData {
    float3 position;
    float rotation;
    float4 color;
    float2 size;
    float2 padding;
};

StructuredBuffer<SpriteData> sprites : register(t0, space0);

static const uint triangleIndices[6] = { 0, 1, 2, 3, 2, 1 };
static const float2 vertexPos[4] = {
    { 0.0f, 0.0f },
    { 1.0f, 0.0f },
    { 0.0f, 1.0f },
    { 1.0f, 1.0f }
};

struct VS_OUTPUT {
    float4 vPosition : SV_Position;
    float4 vColor : TEXCOORD0;
    float2 vTexCoord: TEXCOORD1;
};

VS_OUTPUT main(in uint id : SV_VertexID) {
    uint spriteIndex = id / 6;
    uint vert = triangleIndices[id % 6];
    SpriteData sprite = sprites[spriteIndex];

    float c = cos(sprite.rotation);
    float s = sin(sprite.rotation);

    float2 coord = vertexPos[vert];
    coord *= sprite.size;
    float2x2 rotation = { c, s, -s, c };
    coord = mul(coord, rotation);

    VS_OUTPUT output;
    float4 pos = float4(coord + sprite.position.xy, sprite.position.z, 1.0);
    output.vPosition = mul(uProj, mul(uView, pos));
    output.vColor = sprite.color;
    output.vTexCoord = vertexPos[vert];
    return output;
}

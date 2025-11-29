cbuffer UBO : register(b0, space1) {
    column_major float4x4 uModel;
    column_major float4x4 uView;
    column_major float4x4 uProj;
}

struct VS_INPUT {
    float3 vPosition : TEXCOORD0; 
    float4 vColor : TEXCOORD1;
    float2 vTexCoord : TEXCOORD2;
};

struct VS_OUTPUT {
    float4 vPosition : SV_Position;
    float4 vColor : TEXCOORD0;
    float2 vTexCoord: TEXCOORD1;
};

VS_OUTPUT main(in VS_INPUT input) {
    VS_OUTPUT output;
    float4 pos = float4(input.vPosition, 1.0);
    output.vPosition = mul(uProj, mul(uView, mul(uModel, pos)));;
    output.vColor = input.vColor;
    output.vTexCoord = input.vTexCoord;
    return output;
}
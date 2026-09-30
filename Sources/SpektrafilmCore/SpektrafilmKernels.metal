#include <metal_stdlib>
using namespace metal;

// ── Matrix helpers ──────────────────────────────────────────────
inline float3 mul3(device const float *m, float3 v) {
    return float3(m[0]*v.x+m[1]*v.y+m[2]*v.z,
                  m[3]*v.x+m[4]*v.y+m[5]*v.z,
                  m[6]*v.x+m[7]*v.y+m[8]*v.z);
}
inline float3 mul3c(constant float *m, float3 v) {
    return float3(m[0]*v.x+m[1]*v.y+m[2]*v.z,
                  m[3]*v.x+m[4]*v.y+m[5]*v.z,
                  m[6]*v.x+m[7]*v.y+m[8]*v.z);
}
inline float mitchell(float t) {
    float x = abs(t), B = 1.0f/3.0f, C = 1.0f/3.0f;
    if (x < 1) return ((12-9*B-6*C)*x*x*x + (-18+12*B+6*C)*x*x + (6-2*B)) / 6;
    if (x < 2) return ((-B-6*C)*x*x*x + (6*B+30*C)*x*x + (-12*B-48*C)*x + (8*B+24*C)) / 6;
    return 0;
}
inline int reflecti(int i,int n) {
    if (n <= 1) return 0;
    int period = 2*n;
    int j = i % period;
    if (j < 0) j += period;
    if (j >= n) j = period-1-j;
    return j;
}

// ── Simple elementwise kernels ──────────────────────────────────
kernel void log10_transform(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],constant float& eps[[buffer(2)]],uint id[[thread_position_in_grid]]) {
    output[id] = float4(log10(max(input[id].xyz,float3(0.0f))+eps),0);
}
kernel void blend_buffers(device const float4* a[[buffer(0)]],device const float4* b[[buffer(1)]],device float4* output[[buffer(2)]],constant float& w[[buffer(3)]],uint id[[thread_position_in_grid]]) {
    output[id] = mix(a[id],b[id],w);
}
kernel void add_scaled(device const float4* image[[buffer(0)]],device const float4* field[[buffer(1)]],device float4* output[[buffer(2)]],constant float4& scale[[buffer(3)]],uint id[[thread_position_in_grid]]) {
    output[id] = float4(image[id].xyz+field[id].xyz*scale.xyz,0);
}
kernel void unsharp_combine(device const float4* image[[buffer(0)]],device const float4* blurred[[buffer(1)]],device float4* output[[buffer(2)]],constant float& amount[[buffer(3)]],uint id[[thread_position_in_grid]]) {
    output[id] = float4(image[id].xyz+amount*(image[id].xyz-blurred[id].xyz),0);
}

// ── CAM16 / gamut compression ───────────────────────────────────
inline float signed_powf(float x,float p) {
    return copysign(pow(abs(x),p),x);
}
inline float knee_cam(float d,float threshold,float limit,float power) {
    if (d <= threshold) return d;
    float scale = max(limit-threshold,1e-8f), n = (d-threshold)/scale;
    return threshold+scale*n/pow(1+pow(n,power),1/power);
}
inline float3 m16_mul(float3 v) {
    return float3(0.401288f*v.x+0.650173f*v.y-0.051461f*v.z,
                  -0.250268f*v.x+1.204414f*v.y+0.045854f*v.z,
                  -0.002079f*v.x+0.048952f*v.y+0.953127f*v.z);
}
inline float3 m16_inv_mul(float3 v) {
    return float3(1.86206786f*v.x-1.01125463f*v.y+0.14918677f*v.z,
                  0.38752654f*v.x+0.62144744f*v.y-0.00897398f*v.z,
                  -0.01584150f*v.x-0.03412294f*v.y+1.04996444f*v.z);
}
inline float3 srgb_to_xyz(float3 v) {
    return float3(0.4123908f*v.x+0.35758434f*v.y+0.18048079f*v.z,
                  0.21263901f*v.x+0.71516868f*v.y+0.07219232f*v.z,
                  0.01933082f*v.x+0.11919478f*v.y+0.95053215f*v.z);
}
inline float3 xyz_to_srgb(float3 v) {
    return float3(3.24096994f*v.x-1.53738318f*v.y-0.49861076f*v.z,
                  -0.96924364f*v.x+1.87596750f*v.y+0.04155506f*v.z,
                  0.05563008f*v.x-0.20397696f*v.y+1.05697151f*v.z);
}
inline float adapt_cam(float c,float fl) {
    float x = pow(fl*abs(c)*0.01f,0.42f);
    return copysign(400*x/(x+27.13f),c)+0.1f;
}
inline float unadapt_cam(float c,float fl) {
    float q=c-0.1f, a=min(abs(q),399.9999f), k=100.0f/fl*pow(27.13f,1.0f/0.42f);
    return copysign(k*pow(a/max(400.0f-a,1e-6f),1.0f/0.42f),q);
}
inline float3 xyz_to_jab(float3 xyz,float4 e0,float4 e1,float4 e2,float4 dr) {
    float3 cone = m16_mul(xyz*100.0f)*dr.xyz;
    float3 ra = float3(adapt_cam(cone.x,e0.x),adapt_cam(cone.y,e0.x),adapt_cam(cone.z,e0.x));
    float a=ra.x+(-12*ra.y+ra.z)/11.0f, b=(ra.x+ra.y-2*ra.z)/9.0f, h=atan2(b,a), et=0.25f*(cos(h+2)+3.8f);
    float A = e1.x*(2*ra.x+ra.y+0.05f*ra.z-0.305f);
    float jr = signed_powf(A/e2.x,0.5f*e1.z*e0.w);
    float J = 100*jr*jr;
    float denom = max(ra.x+ra.y+1.05f*ra.z,1e-20f);
    float t = (50000.0f/13.0f*e1.w*e1.y*et*length(float2(a,b)))/denom;
    float alpha = signed_powf(t,0.9f)*pow(1.64f-pow(0.29f,e0.z),0.73f);
    float M = alpha*jr*e0.y, mp=log(1+0.0228f*M)/0.0228f, jp=1.7f*J/(1+0.007f*J);
    return float3(jp,mp*cos(h),mp*sin(h));
}
inline float3 jab_to_xyz(float3 jab,float4 e0,float4 e1,float4 e2,float4 dri) {
    float mp=length(jab.yz), h=atan2(jab.z,jab.y), M=(exp(mp*0.0228f)-1)/0.0228f, J=jab.x/(1-0.007f*(jab.x-100));
    if (J <= 0) return 0;
    float jr = sqrt(J)*0.1f, alpha=(M/e0.y)/max(jr,1e-20f), t=signed_powf(alpha*pow(1.64f-pow(0.29f,e0.z),-0.73f),10.0f/9.0f), et=0.25f*(cos(h+2)+3.8f), A=e2.x*signed_powf(jr,2.0f/(e1.z*e0.w)), p1=50000.0f/13.0f*e1.w*e1.y*et, p2=A/e1.x+0.305f;
    float r = 23*p2*t/max(23*p1+t*(11*cos(h)+108*sin(h)),1e-20f), aa=r*cos(h), bb=r*sin(h);
    float3 tmp = float3(460*p2+451*aa+288*bb,460*p2-891*aa-261*bb,460*p2-220*aa-6300*bb)/1403.0f;
    float3 rgbc = float3(unadapt_cam(tmp.x,e0.x),unadapt_cam(tmp.y,e0.x),unadapt_cam(tmp.z,e0.x));
    return m16_inv_mul(rgbc*dri.xyz)/100.0f;
}
inline float cmax_lookup(float jp,float h,device const float* table,uint2 dims,float2 range) {
    float l=clamp(jp,range.x,range.y), hstep=6.28318530718f/float(dims.y), rawh=(h+3.14159265359f)/hstep, hf=floor(rawh), hfrac=rawh-hf;
    int hlo=((int(hf)%int(dims.y))+int(dims.y))%int(dims.y), hhi=(hlo+1)%int(dims.y);
    float rawl=(l-range.x)/(range.y-range.x)*float(dims.x-1), lf=floor(rawl), lfrac=rawl-lf;
    int llo=clamp(int(lf),0,int(dims.x)-2), lhi=llo+1;
    float v00=table[uint(llo)*dims.y+uint(hlo)], v01=table[uint(llo)*dims.y+uint(hhi)], v10=table[uint(lhi)*dims.y+uint(hlo)], v11=table[uint(lhi)*dims.y+uint(hhi)];
    return mix(mix(v00,v01,hfrac),mix(v10,v11,hfrac),lfrac);
}
kernel void gamut_compress_cam16(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],device const float* table[[buffer(2)]],constant float4& e0[[buffer(3)]],constant float4& e1[[buffer(4)]],constant float4& e2[[buffer(5)]],constant float4& dr[[buffer(6)]],constant float4& dri[[buffer(7)]],constant uint2& dims[[buffer(8)]],constant float4& kp[[buffer(9)]],uint id[[thread_position_in_grid]]) {
    float3 jab = xyz_to_jab(srgb_to_xyz(input[id].xyz),e0,e1,e2,dr);
    jab.x = knee_cam(jab.x/e2.y,0.7f,1.0f,2.2f)*e2.y;
    float cp = length(jab.yz);
    if (cp > 1e-12f) {
        float h = atan2(jab.z,jab.y), boundary=max(cmax_lookup(jab.x,h,table,dims,e2.zw),1e-9f), d=cp/boundary, dc=knee_cam(d,kp.x,kp.y,kp.z), cn=dc*boundary;
        jab.yz = cn*float2(cos(h),sin(h));
    }
    output[id] = float4(xyz_to_srgb(jab_to_xyz(jab,e0,e1,e2,dri)),0);
}
kernel void density_to_rgb_cam16(device const float4* density[[buffer(0)]],device float4* output[[buffer(1)]],device const float* cd[[buffer(2)]],device const float* base[[buffer(3)]],device const float* cmf[[buffer(4)]],device const float* illum[[buffer(5)]],constant uint& n[[buffer(6)]],constant float& norm[[buffer(7)]],constant float* transform[[buffer(8)]],device const float* ok[[buffer(9)]],device const float4* glare[[buffer(10)]],constant float4& glareScale[[buffer(11)]],device const float* table[[buffer(12)]],constant float4& e0[[buffer(13)]],constant float4& e1[[buffer(14)]],constant float4& e2[[buffer(15)]],constant float4& dr[[buffer(16)]],constant float4& dri[[buffer(17)]],constant uint2& dims[[buffer(18)]],constant float4& kp[[buffer(19)]],uint id[[thread_position_in_grid]]) {
    float3 d3 = density[id].xyz, xyz = 0;
    for (uint i = 0; i < n; i++) {
        if (ok[i] < 0.5f) continue;
        float d = base[i]+dot(float3(cd[i*3],cd[i*3+1],cd[i*3+2]),d3);
        float t = pow(10.0f,-d)*illum[i];
        xyz += t*float3(cmf[i*3],cmf[i*3+1],cmf[i*3+2]);
    }
    float3 rgb = mul3c(transform,xyz*norm);
    if (glareScale.w > 0.5f) rgb += glare[id].xyz*glareScale.xyz;
    if (kp.w > 0.5f) {
        float3 jab = xyz_to_jab(srgb_to_xyz(rgb),e0,e1,e2,dr);
        jab.x = knee_cam(jab.x/e2.y,0.7f,1.0f,2.2f)*e2.y;
        float cp = length(jab.yz);
        if (cp > 1e-12f) {
            float h = atan2(jab.z,jab.y), boundary=max(cmax_lookup(jab.x,h,table,dims,e2.zw),1e-9f), dd=cp/boundary, dc=knee_cam(dd,kp.x,kp.y,kp.z), cn=dc*boundary;
            jab.yz = cn*float2(cos(h),sin(h));
        }
        rgb = xyz_to_srgb(jab_to_xyz(jab,e0,e1,e2,dri));
    }
    output[id] = float4(rgb,0);
}
inline float srgb_enc(float x) {
    float v = max(x,0.0f);
    return v <= 0.0031308f ? 12.92f*v : 1.055f*pow(v,1.0f/2.4f)-0.055f;
}
inline float prophoto_enc(float x) {
    float v = max(x,0.0f);
    return v <= 1.0f/512.0f ? v*16.0f : pow(v,1.0f/1.8f);
}
kernel void scanner_finish(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],constant float4& levels[[buffer(2)]],constant uint& mode[[buffer(3)]],uint id[[thread_position_in_grid]]) {
    float3 v = input[id].xyz;
    if (levels.z > 0.5f) {
        float range = max(levels.y-levels.x,1e-6f);
        v = clamp((v-levels.x)/range,0.0f,1.0f);
    }
    if (mode == 1) v = float3(srgb_enc(v.x),srgb_enc(v.y),srgb_enc(v.z));
    else if (mode == 2) v = float3(prophoto_enc(v.x),prophoto_enc(v.y),prophoto_enc(v.z));
    output[id] = float4(v,0);
}

// ── Exposure / combine helpers ──────────────────────────────────
kernel void scale_rgb(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],constant float& scale[[buffer(2)]],uint id[[thread_position_in_grid]]) {
    output[id] = float4(max(input[id].xyz*scale,float3(1e-30f)),0);
}
kernel void reduce_max_rgb(device const float4* input[[buffer(0)]],device atomic_uint* maxBits[[buffer(1)]],uint id[[thread_position_in_grid]]) {
    float m = max(input[id].x,max(input[id].y,input[id].z));
    atomic_fetch_max_explicit(maxBits,as_type<uint>(max(m,0.0f)),memory_order_relaxed);
}
kernel void boost_highlights(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],device const uint* maxBits[[buffer(2)]],constant float4& p[[buffer(3)]],uint id[[thread_position_in_grid]]) {
    float maxRaw = as_type<float>(maxBits[0]);
    float3 x = input[id].xyz;
    if (p.x <= 0.0f || maxRaw <= 0.0f) {
        output[id] = input[id];
        return;
    }
    float rawX0 = min(max(p.w*exp2(p.z),0.0f),maxRaw);
    if (rawX0 >= maxRaw) {
        output[id] = input[id];
        return;
    }
    float a = pow(28.0f,1.0f-clamp(p.y,0.0f,1.0f));
    float denom = exp(a*(1.0f-rawX0/maxRaw))-a*(1.0f-rawX0/maxRaw)-1.0f;
    if (denom <= 0.0f) {
        output[id] = input[id];
        return;
    }
    float k = (exp2(p.x)-1.0f)/denom;
    float inv = 1.0f/maxRaw, sc = k*maxRaw;
    for (uint c = 0; c < 3; c++) {
        if (x[c] > rawX0) {
            float dx = (x[c]-rawX0)*inv;
            x[c] += sc*(exp(a*dx)-a*dx-1.0f);
        }
    }
    output[id] = float4(x,0);
}
kernel void linear_combine(device const float4* a[[buffer(0)]],device const float4* b[[buffer(1)]],device float4* output[[buffer(2)]],constant float2& w[[buffer(3)]],uint id[[thread_position_in_grid]]) {
    output[id] = a[id]*w.x+b[id]*w.y;
}
kernel void combine_channels(device const float4* a[[buffer(0)]],device const float4* b[[buffer(1)]],device float4* output[[buffer(2)]],constant float4& wa[[buffer(3)]],constant float4& wb[[buffer(4)]],uint id[[thread_position_in_grid]]) {
    output[id] = float4(a[id].xyz*wa.xyz+b[id].xyz*wb.xyz,0);
}

// ── Film / print / scan kernels ─────────────────────────────────
kernel void rgb_to_film_raw(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],device const float* lut[[buffer(2)]],constant float* mats[[buffer(3)]],constant uint2& dims[[buffer(4)]],uint id[[thread_position_in_grid]]) {
    float3 rgb = input[id].xyz;
    float3 xyz0 = mul3c(mats,rgb);
    float3 xyz = mul3c(mats+9,xyz0);
    float b = xyz.x+xyz.y+xyz.z;
    if (b <= 1e-10f) {
        output[id] = 0;
        return;
    }
    float x = xyz.x/b, y = xyz.y/b, q = max(1-x,1e-10f), tx=clamp(q*q,0.0f,1.0f), ty=clamp(y/q,0.0f,1.0f);
    float fx = tx*(dims.x-1), fy = ty*(dims.y-1);
    int xi = min(int(fx),int(dims.x)-2), yi = min(int(fy),int(dims.y)-2);
    float dx = fx-xi, dy = fy-yi;
    float3 r = 0;
    float ws = 0;
    for (int a = 0; a < 4; a++) {
        int xx = reflecti(xi+a-1,int(dims.x));
        float wx = mitchell(dx-(a-1));
        for (int bb = 0; bb < 4; bb++) {
            int yy = reflecti(yi+bb-1,int(dims.y));
            float w = wx*mitchell(dy-(bb-1));
            uint base = (uint(xx)*dims.y+uint(yy))*3;
            r += w*float3(lut[base],lut[base+1],lut[base+2]);
            ws += w;
        }
    }
    r /= max(ws,1e-20f);
    output[id] = float4(max(r*b,float3(1e-30f)),0);
}
kernel void print_exposure(device const float4* density[[buffer(0)]],device float4* output[[buffer(1)]],device const float* cd[[buffer(2)]],device const float* base[[buffer(3)]],device const float* sens[[buffer(4)]],device const float* illum[[buffer(5)]],constant uint& n[[buffer(6)]],constant float4& pre[[buffer(7)]],constant float& scale[[buffer(8)]],device const float* ok[[buffer(9)]],uint id[[thread_position_in_grid]]) {
    float3 d3 = density[id].xyz, raw = 0;
    for (uint i = 0; i < n; i++) {
        if (ok[i] < 0.5f) continue;
        float d = base[i]+dot(float3(cd[i*3],cd[i*3+1],cd[i*3+2]),d3);
        float t = pow(10.0f,-d)*illum[i];
        raw += t*float3(sens[i*3],sens[i*3+1],sens[i*3+2]);
    }
    output[id] = float4(max((raw+pre.xyz)*scale,float3(1e-30f)),0);
}
kernel void density_to_rgb(device const float4* density[[buffer(0)]],device float4* output[[buffer(1)]],device const float* cd[[buffer(2)]],device const float* base[[buffer(3)]],device const float* cmf[[buffer(4)]],device const float* illum[[buffer(5)]],constant uint& n[[buffer(6)]],constant float& norm[[buffer(7)]],constant float* transform[[buffer(8)]],device const float* ok[[buffer(9)]],uint id[[thread_position_in_grid]]) {
    float3 d3 = density[id].xyz, xyz = 0;
    for (uint i = 0; i < n; i++) {
        if (ok[i] < 0.5f) continue;
        float d = base[i]+dot(float3(cd[i*3],cd[i*3+1],cd[i*3+2]),d3);
        float t = pow(10.0f,-d)*illum[i];
        xyz += t*float3(cmf[i*3],cmf[i*3+1],cmf[i*3+2]);
    }
    output[id] = float4(mul3c(transform,xyz*norm),0);
}
inline float interp_curve(float q,device const float* axis,device const float* curves,uint n,uint c,float gamma) {
    float qq = q;
    float a0 = axis[0]/gamma, a1 = axis[n-1]/gamma;
    if (qq <= a0) return curves[c];
    if (qq >= a1) return curves[(n-1)*3+c];
    uint lo = 0, hi = n-1;
    while (hi-lo > 1) {
        uint m = (lo+hi)>>1;
        if (axis[m]/gamma <= qq) lo = m;
        else hi = m;
    }
    float xl = axis[lo]/gamma, xh = axis[hi]/gamma;
    float t = (qq-xl)/max(xh-xl,1e-20f);
    return mix(curves[lo*3+c],curves[hi*3+c],t);
}
kernel void develop_linear(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],device const float* axis[[buffer(2)]],device const float* curves[[buffer(3)]],constant uint& n[[buffer(4)]],constant float& gamma[[buffer(5)]],uint id[[thread_position_in_grid]]) {
    float3 q = input[id].xyz;
    output[id] = float4(interp_curve(q.x,axis,curves,n,0,gamma),interp_curve(q.y,axis,curves,n,1,gamma),interp_curve(q.z,axis,curves,n,2,gamma),0);
}
kernel void dir_inhibitor(device const float4* density[[buffer(0)]],device float4* output[[buffer(1)]],device const float* m[[buffer(2)]],constant float4& maxD[[buffer(3)]],constant uint& positive[[buffer(4)]],uint id[[thread_position_in_grid]]) {
    float3 d = density[id].xyz;
    float3 silver = positive != 0 ? maxD.xyz-d : d;
    float3 r = float3(dot(silver,float3(m[0],m[3],m[6])),dot(silver,float3(m[1],m[4],m[7])),dot(silver,float3(m[2],m[5],m[8])));
    output[id] = float4(r,0);
}
kernel void dir_redevelop(device const float4* raw[[buffer(0)]],device const float4* inhibitor[[buffer(1)]],device float4* output[[buffer(2)]],device const float* axis[[buffer(3)]],device const float* curves[[buffer(4)]],constant uint& n[[buffer(5)]],constant float& gamma[[buffer(6)]],uint id[[thread_position_in_grid]]) {
    float3 q = raw[id].xyz-inhibitor[id].xyz;
    output[id] = float4(interp_curve(q.x,axis,curves,n,0,gamma),interp_curve(q.y,axis,curves,n,1,gamma),interp_curve(q.z,axis,curves,n,2,gamma),0);
}
kernel void accumulate_weighted(device const float4* input[[buffer(0)]],device float4* accum[[buffer(1)]],constant float& weight[[buffer(2)]],uint id[[thread_position_in_grid]]) {
    accum[id] += input[id]*weight;
}

// ── Grain kernels ───────────────────────────────────────────────
inline uint hash32(uint x) {
    x ^= x>>16;
    x *= 0x7feb352du;
    x ^= x>>15;
    x *= 0x846ca68bu;
    x ^= x>>16;
    return x;
}
inline float rand01(uint x) {
    return (float(hash32(x))+0.5f)/4294967296.0f;
}
inline float normal01(uint a,uint b) {
    float u = max(rand01(a),1e-7f), v = rand01(b);
    return sqrt(-2.0f*log(u))*cos(6.28318530718f*v);
}
inline float particle_approx(float density,float dmax,float npp,float uniformity,uint seed) {
    float p = clamp(density/max(dmax,1e-20f),1e-6f,1.0f-1e-6f);
    float sat = 1.0f-p*uniformity*(1.0f-1e-6f);
    float lambda = npp/max(sat,1e-12f);
    float mean = lambda*p;
    float variance = max(lambda*p*(1.0f-p)+lambda*p*p,1e-8f);
    float developed = max(0.0f,mean+sqrt(variance)*normal01(seed,seed^0x9e3779b9u));
    return developed*(dmax/max(npp,1e-20f))*sat;
}
inline float interp_axis(float q,device const float* xa,device const float* ya,uint n) {
    if (q <= xa[0]) return ya[0];
    if (q >= xa[n-1]) return ya[n-1];
    uint lo = 0, hi = n-1;
    while (hi-lo > 1) {
        uint m = (lo+hi)>>1;
        if (xa[m] <= q) lo = m;
        else hi = m;
    }
    float t = (q-xa[lo])/max(xa[hi]-xa[lo],1e-20f);
    return mix(ya[lo],ya[hi],t);
}
kernel void grain_simple(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],constant float4& dmax[[buffer(2)]],constant float4& dmin[[buffer(3)]],constant float4& pscale[[buffer(4)]],constant float4& uniformity[[buffer(5)]],constant float& particleArea[[buffer(6)]],constant float& pixelArea[[buffer(7)]],constant uint& sublayers[[buffer(8)]],constant ulong& seed64[[buffer(9)]],constant uint2& origin[[buffer(10)]],constant uint& sourceWidth[[buffer(11)]],constant uint& localWidth[[buffer(12)]],constant float& invScale[[buffer(13)]],uint id[[thread_position_in_grid]]) {
    float3 r = 0;
    uint lx = id%max(localWidth,1u), ly = id/max(localWidth,1u);
    uint sx = origin.x+uint(float(lx)*invScale), sy = origin.y+uint(float(ly)*invScale);
    uint globalId = sx+sy*max(sourceWidth,1u);
    uint base = uint(seed64)^hash32(globalId)*0x85ebca6bu;
    for (uint c = 0; c < 3; c++) {
        float acc = 0;
        float npp = max(pixelArea/(particleArea*pscale[c])/float(max(sublayers,1u)),1e-6f);
        for (uint s = 0; s < max(sublayers,1u); s++) {
            uint h = base+c*0x27d4eb2du+s*0x165667b1u;
            acc += particle_approx(max(input[id][c]+dmin[c],0.0f),max(dmax[c],1e-9f),npp,uniformity[c],h);
        }
        r[c] = acc/float(max(sublayers,1u))-dmin[c];
    }
    output[id] = float4(r,0);
}
kernel void grain_layers(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],device const float* xaxes[[buffer(2)]],device const float* yaxes[[buffer(3)]],device const float* dmax[[buffer(4)]],device const float* dmin[[buffer(5)]],device const float* fractions[[buffer(6)]],device const float* scales[[buffer(7)]],constant float4& layerScale[[buffer(8)]],constant float& particleArea[[buffer(9)]],constant float& pixelArea[[buffer(10)]],constant uint& n[[buffer(11)]],constant uint& positive[[buffer(12)]],constant ulong& seed64[[buffer(13)]],constant uint2& origin[[buffer(14)]],constant uint& sourceWidth[[buffer(15)]],constant uint& localWidth[[buffer(16)]],constant float& invScale[[buffer(17)]],uint id[[thread_position_in_grid]]) {
    float3 outv = 0;
    uint lx = id%max(localWidth,1u), ly = id/max(localWidth,1u);
    uint sx = origin.x+uint(float(lx)*invScale), sy = origin.y+uint(float(ly)*invScale);
    uint globalId = sx+sy*max(sourceWidth,1u);
    uint base = uint(seed64)^hash32(globalId)*0x85ebca6bu;
    for (uint c = 0; c < 3; c++) {
        float total = 0;
        float q = positive != 0 ? -input[id][c] : input[id][c];
        for (uint sl = 0; sl < 3; sl++) {
            uint idx = sl*3+c;
            device const float* xa = xaxes+idx*n;
            device const float* ya = yaxes+idx*n;
            float ld = interp_axis(q,xa,ya,n);
            if (positive != 0) ld = -ld;
            ld = max(ld+dmin[idx],0.0f);
            float npp = max(pixelArea*fractions[idx]/max(particleArea*scales[c]*layerScale[sl],1e-12f),1e-9f);
            uint h = base+idx*0x27d4eb2du;
            total += particle_approx(ld,max(dmax[idx],1e-9f),npp,scales[3+c],h);
        }
        outv[c] = total-(dmin[c]+dmin[3+c]+dmin[6+c]);
    }
    output[id] = float4(outv,0);
}

// ── Blur kernels ────────────────────────────────────────────────
kernel void gaussian_h(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],constant uint2& wh[[buffer(2)]],constant float4& sigma[[buffer(3)]],constant int& radius[[buffer(4)]],uint id[[thread_position_in_grid]]) {
    uint x = id%wh.x, y = id/wh.x;
    if (y >= wh.y) return;
    float3 sum = 0, ws = 0;
    for (int k = -radius; k <= radius; k++) {
        int xx = reflecti(int(x)+k,int(wh.x));
        float3 s = max(sigma.xyz,float3(1e-6f));
        float3 w = exp(-0.5f*(float(k*k))/(s*s));
        sum += input[y*wh.x+xx].xyz*w;
        ws += w;
    }
    float3 orig = input[id].xyz;
    float3 r = select(sum/max(ws,float3(1e-20f)),orig,sigma.xyz<=float3(0.05f));
    output[id] = float4(r,0);
}
kernel void gaussian_v(device const float4* input[[buffer(0)]],device float4* output[[buffer(1)]],constant uint2& wh[[buffer(2)]],constant float4& sigma[[buffer(3)]],constant int& radius[[buffer(4)]],uint id[[thread_position_in_grid]]) {
    uint x = id%wh.x, y = id/wh.x;
    if (y >= wh.y) return;
    float3 sum = 0, ws = 0;
    for (int k = -radius; k <= radius; k++) {
        int yy = reflecti(int(y)+k,int(wh.y));
        float3 s = max(sigma.xyz,float3(1e-6f));
        float3 w = exp(-0.5f*(float(k*k))/(s*s));
        sum += input[yy*wh.x+x].xyz*w;
        ws += w;
    }
    float3 orig = input[id].xyz;
    float3 r = select(sum/max(ws,float3(1e-20f)),orig,sigma.xyz<=float3(0.05f));
    output[id] = float4(r,0);
}

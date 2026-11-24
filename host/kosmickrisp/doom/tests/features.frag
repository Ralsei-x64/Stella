#version 450
#extension GL_ARB_gpu_shader_fp64 : require
layout(push_constant) uniform Params { float inputValue; } pc;
layout(location=0) out vec4 color;
void main() {
    double d = double(pc.inputValue);
    color = uint(d*d) == 16785409u ? vec4(0,1,0,1) : vec4(1,0,0,1);
}

// GPU smoke test: one render and one compute dispatch on the GPU's render
// node, read back.
//
// EGL surfaceless (no display, no window), OpenGL ES 3.1:
// - render: clears a 64x64 framebuffer object to a known color, draws one
//   triangle over its centre, reads the pixels back and checks both;
// - compute: a 64-invocation compute shader writes i * 3 + 7 into a storage
//   buffer, which is mapped back and checked.
// Exit 0 = both ran on the GPU.
//
// Run with Aurora's Mesa (see default.nix): ./result/bin/gpu-smoke
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <stdio.h>
#include <stdlib.h>

#define W 64
#define H 64

static GLuint shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	GLint ok;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[512];
		glGetShaderInfoLog(s, sizeof log, NULL, log);
		fprintf(stderr, "shader: %s\n", log);
		exit(2);
	}
	return s;
}

int main(void)
{
	PFNEGLGETPLATFORMDISPLAYEXTPROC get_display =
		(void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
	EGLDisplay dpy = get_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
	if (!eglInitialize(dpy, NULL, NULL)) {
		fprintf(stderr, "eglInitialize failed: %#x\n", eglGetError());
		return 2;
	}
	eglBindAPI(EGL_OPENGL_ES_API);
	EGLint cfg_attr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, 0, EGL_NONE };
	EGLConfig cfg;
	EGLint n;
	if (!eglChooseConfig(dpy, cfg_attr, &cfg, 1, &n) || n < 1)
		cfg = EGL_NO_CONFIG_KHR;
	EGLint ctx_attr[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
	if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
		fprintf(stderr, "context failed: %#x\n", eglGetError());
		return 2;
	}
	printf("GL_RENDERER: %s\nGL_VERSION: %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));

	GLuint tex, fbo;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		fprintf(stderr, "framebuffer incomplete\n");
		return 2;
	}
	glViewport(0, 0, W, H);

	GLuint prog = glCreateProgram();
	glAttachShader(prog, shader(GL_VERTEX_SHADER,
		"attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }"));
	glAttachShader(prog, shader(GL_FRAGMENT_SHADER,
		"precision mediump float; void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }"));
	glBindAttribLocation(prog, 0, "p");
	glLinkProgram(prog);
	glUseProgram(prog);
	static const GLfloat tri[] = { -0.5f, -0.5f, 0.5f, -0.5f, 0.0f, 0.5f };
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, tri);
	glEnableVertexAttribArray(0);

	glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glFinish();

	static unsigned char px[W * H * 4];
	glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
	unsigned char *corner = &px[0], *centre = &px[((H / 2) * W + W / 2) * 4];
	printf("corner %02x%02x%02x%02x (want ff0000ff), centre %02x%02x%02x%02x (want 00ff00ff)\n",
	       corner[0], corner[1], corner[2], corner[3], centre[0], centre[1], centre[2], centre[3]);
	int render_ok = corner[0] == 0xff && corner[1] == 0 && centre[0] == 0 && centre[1] == 0xff;
	printf("render %s\n", render_ok ? "PASS" : "FAIL");

	GLuint cs = shader(GL_COMPUTE_SHADER,
		"#version 310 es\n"
		"layout(local_size_x = 64) in;\n"
		"layout(std430, binding = 0) buffer B { uint v[]; };\n"
		"void main() { uint i = gl_GlobalInvocationID.x; v[i] = i * 3u + 7u; }\n");
	GLuint cprog = glCreateProgram();
	glAttachShader(cprog, cs);
	glLinkProgram(cprog);
	GLint linked;
	glGetProgramiv(cprog, GL_LINK_STATUS, &linked);
	if (!linked) {
		fprintf(stderr, "compute program did not link\n");
		return 2;
	}
	GLuint buf;
	glGenBuffers(1, &buf);
	glBindBuffer(GL_SHADER_STORAGE_BUFFER, buf);
	static GLuint zero[64];
	glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof zero, zero, GL_DYNAMIC_READ);
	glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buf);
	glUseProgram(cprog);
	glDispatchCompute(1, 1, 1);
	glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
	glFinish();
	const GLuint *out = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, sizeof zero, GL_MAP_READ_BIT);
	int compute_ok = out != NULL;
	for (int i = 0; compute_ok && i < 64; i++)
		compute_ok = out[i] == (GLuint)i * 3 + 7;
	printf("compute v[0..3] = %u %u %u %u (want 7 10 13 16), v[63] = %u (want 196)\n",
	       out ? out[0] : 0, out ? out[1] : 0, out ? out[2] : 0, out ? out[3] : 0, out ? out[63] : 0);
	printf("compute %s\n", compute_ok ? "PASS" : "FAIL");
	int ok = render_ok && compute_ok;
	printf("%s\n", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}

// OpenGL 3.3 core backend. The whole grid is one draw call: an instanced
// quad per cell, with the cell's character as the per-instance attribute.
// Read: LearnOpenGL "Hello Triangle", "Shaders", "Textures" and
// "Instancing".

#include <GL/glcorearb.h>
#include <SDL3/SDL.h>
#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "../core/backend.h"

// The shaders are baked into the binary at compile time with C23 #embed,
// with a trailing NUL so they're C strings.
static const char cell_vert_src[] = {
#embed "shaders/cell.vert" suffix(, '\0')
};
static const char cell_frag_src[] = {
#embed "shaders/cell.frag" suffix(, '\0')
};

// Every GL function we call, loaded at runtime through SDL. Core-profile GL
// has no link-time entry points we can rely on; the driver hands them out.
#define GL_FUNCS(X)                                                                       \
    X(PFNGLCLEARCOLORPROC, ClearColor)                                                    \
    X(PFNGLCLEARPROC, Clear)                                                              \
    X(PFNGLVIEWPORTPROC, Viewport)                                                        \
    X(PFNGLGETERRORPROC, GetError)                                                        \
    X(PFNGLCREATESHADERPROC, CreateShader)                                                \
    X(PFNGLSHADERSOURCEPROC, ShaderSource)                                                \
    X(PFNGLCOMPILESHADERPROC, CompileShader)                                              \
    X(PFNGLGETSHADERIVPROC, GetShaderiv)                                                  \
    X(PFNGLGETSHADERINFOLOGPROC, GetShaderInfoLog)                                        \
    X(PFNGLDELETESHADERPROC, DeleteShader)                                                \
    X(PFNGLCREATEPROGRAMPROC, CreateProgram)                                              \
    X(PFNGLATTACHSHADERPROC, AttachShader)                                                \
    X(PFNGLLINKPROGRAMPROC, LinkProgram)                                                  \
    X(PFNGLGETPROGRAMIVPROC, GetProgramiv)                                                \
    X(PFNGLGETPROGRAMINFOLOGPROC, GetProgramInfoLog)                                      \
    X(PFNGLUSEPROGRAMPROC, UseProgram)                                                    \
    X(PFNGLDELETEPROGRAMPROC, DeleteProgram)                                              \
    X(PFNGLGETUNIFORMLOCATIONPROC, GetUniformLocation)                                    \
    X(PFNGLUNIFORM1IPROC, Uniform1i)                                                      \
    X(PFNGLUNIFORM2FPROC, Uniform2f)                                                      \
    X(PFNGLUNIFORM3FPROC, Uniform3f)                                                      \
    X(PFNGLGENVERTEXARRAYSPROC, GenVertexArrays)                                          \
    X(PFNGLBINDVERTEXARRAYPROC, BindVertexArray)                                          \
    X(PFNGLDELETEVERTEXARRAYSPROC, DeleteVertexArrays)                                    \
    X(PFNGLGENBUFFERSPROC, GenBuffers)                                                    \
    X(PFNGLBINDBUFFERPROC, BindBuffer)                                                    \
    X(PFNGLBUFFERDATAPROC, BufferData)                                                    \
    X(PFNGLBUFFERSUBDATAPROC, BufferSubData)                                              \
    X(PFNGLDELETEBUFFERSPROC, DeleteBuffers)                                              \
    X(PFNGLENABLEVERTEXATTRIBARRAYPROC, EnableVertexAttribArray)                          \
    X(PFNGLVERTEXATTRIBIPOINTERPROC, VertexAttribIPointer)                                \
    X(PFNGLVERTEXATTRIBDIVISORPROC, VertexAttribDivisor)                                  \
    X(PFNGLGENTEXTURESPROC, GenTextures)                                                  \
    X(PFNGLBINDTEXTUREPROC, BindTexture)                                                  \
    X(PFNGLACTIVETEXTUREPROC, ActiveTexture)                                              \
    X(PFNGLTEXIMAGE2DPROC, TexImage2D)                                                    \
    X(PFNGLTEXPARAMETERIPROC, TexParameteri)                                              \
    X(PFNGLPIXELSTOREIPROC, PixelStorei)                                                  \
    X(PFNGLDELETETEXTURESPROC, DeleteTextures)                                            \
    X(PFNGLDRAWARRAYSINSTANCEDPROC, DrawArraysInstanced)

struct gl_funcs {
#define X(type, name) type name;
    GL_FUNCS(X)
#undef X
};

struct gl {
    SDL_Window *window;
    SDL_GLContext context;
    struct gl_funcs f;
    GLuint program, vao, cell_buffer, atlas_texture;
    uint16_t cols, rows;
    int width, height; // drawable size in pixels
    int cell_w, cell_h;
    struct {
        GLint viewport, origin, cell, cols, atlas_cols, first_char, cursor, atlas, fg, bg;
    } u; // uniform locations
};

// Tomorrow Night-ish colors; themes come with MVP 4's config.
static constexpr float fg_rgb[3] = {0.773f, 0.784f, 0.776f};
static constexpr float bg_rgb[3] = {0.114f, 0.122f, 0.129f};

[[nodiscard]] static bool load_funcs(struct gl_funcs *f) {
#define X(type, name)                                                                     \
    f->name = (type)SDL_GL_GetProcAddress("gl" #name);                                    \
    if (f->name == nullptr) {                                                             \
        fprintf(stderr, "renderer: missing gl" #name "\n");                               \
        return false;                                                                     \
    }
    GL_FUNCS(X)
#undef X
    return true;
}

[[nodiscard]] static GLuint compile(struct gl *gl, GLenum kind, const char *src) {
    GLuint shader = gl->f.CreateShader(kind);
    gl->f.ShaderSource(shader, 1, &src, nullptr);
    gl->f.CompileShader(shader);
    GLint ok;
    gl->f.GetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        gl->f.GetShaderInfoLog(shader, sizeof log, nullptr, log);
        fprintf(stderr, "renderer: shader compile failed:\n%s\n", log);
        gl->f.DeleteShader(shader);
        return 0;
    }
    return shader;
}

[[nodiscard]] static bool build_program(struct gl *gl) {
    GLuint vs = compile(gl, GL_VERTEX_SHADER, cell_vert_src);
    GLuint fs = compile(gl, GL_FRAGMENT_SHADER, cell_frag_src);
    if (vs == 0 || fs == 0) {
        gl->f.DeleteShader(vs);
        gl->f.DeleteShader(fs);
        return false;
    }
    gl->program = gl->f.CreateProgram();
    gl->f.AttachShader(gl->program, vs);
    gl->f.AttachShader(gl->program, fs);
    gl->f.LinkProgram(gl->program);
    gl->f.DeleteShader(vs); // the program keeps what it needs
    gl->f.DeleteShader(fs);
    GLint ok;
    gl->f.GetProgramiv(gl->program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        gl->f.GetProgramInfoLog(gl->program, sizeof log, nullptr, log);
        fprintf(stderr, "renderer: shader link failed:\n%s\n", log);
        return false;
    }

#define LOC(field, name) gl->u.field = gl->f.GetUniformLocation(gl->program, name)
    LOC(viewport, "u_viewport");
    LOC(origin, "u_origin");
    LOC(cell, "u_cell");
    LOC(cols, "u_cols");
    LOC(atlas_cols, "u_atlas_cols");
    LOC(first_char, "u_first_char");
    LOC(cursor, "u_cursor");
    LOC(atlas, "u_atlas");
    LOC(fg, "u_fg");
    LOC(bg, "u_bg");
#undef LOC
    return true;
}

static bool gl_configure(void) {
    return SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3) &&
           SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3) &&
           SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE) &&
           SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
}

static void gl_shutdown(void *state);

static void *gl_init(SDL_Window *window, uint16_t cols, uint16_t rows) {
    struct gl *gl = calloc(1, sizeof *gl);
    if (gl == nullptr)
        return nullptr;
    gl->window = window;
    gl->cols = cols;
    gl->rows = rows;

    gl->context = SDL_GL_CreateContext(window);
    if (gl->context == nullptr) {
        fprintf(stderr, "renderer: no OpenGL 3.3 core context: %s\n", SDL_GetError());
        free(gl);
        return nullptr;
    }
    // Wait for vsync on swap: draw at most once per screen refresh.
    SDL_GL_SetSwapInterval(1);
    if (!load_funcs(&gl->f) || !build_program(gl)) {
        gl_shutdown(gl);
        return nullptr;
    }

    // The per-cell buffer: one byte per cell, fed to a_glyph once per
    // instance (divisor 1) instead of once per vertex.
    size_t ncells;
    if (ckd_mul(&ncells, (size_t)cols, (size_t)rows)) {
        gl_shutdown(gl);
        return nullptr;
    }
    gl->f.GenVertexArrays(1, &gl->vao);
    gl->f.BindVertexArray(gl->vao);
    gl->f.GenBuffers(1, &gl->cell_buffer);
    gl->f.BindBuffer(GL_ARRAY_BUFFER, gl->cell_buffer);
    gl->f.BufferData(GL_ARRAY_BUFFER, (GLsizeiptr)ncells, nullptr, GL_DYNAMIC_DRAW);
    gl->f.EnableVertexAttribArray(0);
    gl->f.VertexAttribIPointer(0, 1, GL_UNSIGNED_BYTE, 1, nullptr);
    gl->f.VertexAttribDivisor(0, 1);
    return gl;
}

static bool gl_upload_atlas(void *state, const struct atlas *atlas) {
    struct gl *gl = state;
    gl->cell_w = atlas->cell_w;
    gl->cell_h = atlas->cell_h;
    gl->f.GenTextures(1, &gl->atlas_texture);
    gl->f.ActiveTexture(GL_TEXTURE0);
    gl->f.BindTexture(GL_TEXTURE_2D, gl->atlas_texture);
    // Rows of an 8-bit bitmap aren't 4-byte aligned; tell GL not to assume so.
    gl->f.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
    gl->f.TexImage2D(GL_TEXTURE_2D, 0, GL_R8, atlas->width, atlas->height, 0, GL_RED,
                     GL_UNSIGNED_BYTE, atlas->pixels);
    gl->f.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl->f.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    return gl->f.GetError() == GL_NO_ERROR;
}

static void gl_resize(void *state, int width_px, int height_px) {
    struct gl *gl = state;
    gl->width = width_px;
    gl->height = height_px;
    gl->f.Viewport(0, 0, width_px, height_px);
}

static void gl_draw_frame(void *state, const struct frame *frame) {
    struct gl *gl = state;
    struct gl_funcs *f = &gl->f;
    GLsizei ncells = (GLsizei)frame->cols * frame->rows;

    f->ClearColor(bg_rgb[0], bg_rgb[1], bg_rgb[2], 1.0f);
    f->Clear(GL_COLOR_BUFFER_BIT);

    // MVP 1 re-uploads every cell each frame: 1920 bytes. Damage tracking
    // comes in MVP 3.
    f->BindBuffer(GL_ARRAY_BUFFER, gl->cell_buffer);
    f->BufferSubData(GL_ARRAY_BUFFER, 0, ncells, frame->cells);

    f->UseProgram(gl->program);
    f->Uniform2f(gl->u.viewport, (float)gl->width, (float)gl->height);
    f->Uniform2f(gl->u.origin, (float)frame->origin_x, (float)frame->origin_y);
    f->Uniform2f(gl->u.cell, (float)gl->cell_w, (float)gl->cell_h);
    f->Uniform1i(gl->u.cols, frame->cols);
    f->Uniform1i(gl->u.atlas_cols, atlas_grid_cols);
    f->Uniform1i(gl->u.first_char, atlas_first_char);
    f->Uniform1i(gl->u.cursor, frame->cursor_row * frame->cols + frame->cursor_col);
    f->Uniform1i(gl->u.atlas, 0);
    f->Uniform3f(gl->u.fg, fg_rgb[0], fg_rgb[1], fg_rgb[2]);
    f->Uniform3f(gl->u.bg, bg_rgb[0], bg_rgb[1], bg_rgb[2]);

    f->BindVertexArray(gl->vao);
    f->ActiveTexture(GL_TEXTURE0);
    f->BindTexture(GL_TEXTURE_2D, gl->atlas_texture);
    f->DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, ncells);

    SDL_GL_SwapWindow(gl->window);
}

static void gl_shutdown(void *state) {
    struct gl *gl = state;
    if (gl == nullptr)
        return;
    if (gl->f.DeleteTextures != nullptr) {
        gl->f.DeleteTextures(1, &gl->atlas_texture);
        gl->f.DeleteBuffers(1, &gl->cell_buffer);
        gl->f.DeleteVertexArrays(1, &gl->vao);
        gl->f.DeleteProgram(gl->program);
    }
    if (gl->context != nullptr)
        SDL_GL_DestroyContext(gl->context);
    free(gl);
}

const struct backend renderer_backend = {
    .name = "gl",
    .window_flags = SDL_WINDOW_OPENGL,
    .configure = gl_configure,
    .init = gl_init,
    .upload_atlas = gl_upload_atlas,
    .draw_frame = gl_draw_frame,
    .resize = gl_resize,
    .shutdown = gl_shutdown,
};

package com.blaineam.haven.core

import android.graphics.Bitmap
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLUtils
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Applies a [FilterSpec] to a still photo with an offscreen OpenGL pass, using the SAME GLSL shader
 * the video transcoder uses — so a filtered photo and a filtered video are pixel-consistent (and
 * both match the iOS Core Image pipeline's look). Runs fully offscreen (EGL pbuffer); no view needed.
 */
object GlPhotoFilter {
    private const val TAG = "GlPhotoFilter"

    // Full-screen quad. Texture coords map position directly (no V-flip): GLUtils uploads the bitmap
    // top-row-first, so the on-screen image is vertically flipped, and glReadPixels (bottom-up) flips
    // it back — the read-back rows come out top-first, i.e. upright.
    private val quad = floatArrayOf(
        // x, y,    u, v
        -1f, -1f, 0f, 0f,
        1f, -1f, 1f, 0f,
        -1f, 1f, 0f, 1f,
        1f, 1f, 1f, 1f,
    )

    fun apply(src: Bitmap, spec: FilterSpec): Bitmap {
        if (spec == FilterSpec()) return src // Original — nothing to do
        val w = src.width; val h = src.height
        var display: EGLDisplay? = null
        var context: EGLContext? = null
        var surface: EGLSurface? = null
        try {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            EGL14.eglInitialize(display, IntArray(1), 0, IntArray(1), 0)
            val cfg = arrayOfNulls<EGLConfig>(1)
            EGL14.eglChooseConfig(display, intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8, EGL14.EGL_NONE,
            ), 0, cfg, 0, 1, IntArray(1), 0)
            context = EGL14.eglCreateContext(display, cfg[0], EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
            surface = EGL14.eglCreatePbufferSurface(display, cfg[0],
                intArrayOf(EGL14.EGL_WIDTH, w, EGL14.EGL_HEIGHT, h, EGL14.EGL_NONE), 0)
            EGL14.eglMakeCurrent(display, surface, surface, context)

            val program = buildProgram(FilterShader.VERTEX, FilterShader.fragmentFor(spec))
            GLES20.glUseProgram(program)

            // Upload the source bitmap as a 2D texture.
            val tex = IntArray(1); GLES20.glGenTextures(1, tex, 0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex[0])
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, src, 0)

            val buf: FloatBuffer = ByteBuffer.allocateDirect(quad.size * 4).order(ByteOrder.nativeOrder())
                .asFloatBuffer().apply { put(quad); position(0) }
            val aPos = GLES20.glGetAttribLocation(program, "aPosition")
            val aTex = GLES20.glGetAttribLocation(program, "aTextureCoord")
            buf.position(0)
            GLES20.glEnableVertexAttribArray(aPos)
            GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, buf)
            buf.position(2)
            GLES20.glEnableVertexAttribArray(aTex)
            GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 16, buf)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "sTexture"), 0)

            GLES20.glViewport(0, 0, w, h)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GLES20.glFinish()

            // Read back RGBA → ARGB bitmap.
            val pixels = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
            GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixels)
            pixels.rewind()
            val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            out.copyPixelsFromBuffer(pixels)   // RGBA buffer → ARGB_8888 (Android handles channel order)
            GLES20.glDeleteTextures(1, tex, 0)
            GLES20.glDeleteProgram(program)
            return out
        } catch (t: Throwable) {
            Log.e(TAG, "photo filter failed", t)
            return src
        } finally {
            if (display != null) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (surface != null) EGL14.eglDestroySurface(display, surface)
                if (context != null) EGL14.eglDestroyContext(display, context)
                EGL14.eglTerminate(display)
            }
        }
    }

    private fun buildProgram(vs: String, fs: String): Int {
        val v = compile(GLES20.GL_VERTEX_SHADER, vs)
        val f = compile(GLES20.GL_FRAGMENT_SHADER, fs)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, v); GLES20.glAttachShader(p, f); GLES20.glLinkProgram(p)
        val ok = IntArray(1); GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
        if (ok[0] == 0) Log.e(TAG, "link: ${GLES20.glGetProgramInfoLog(p)}")
        GLES20.glDeleteShader(v); GLES20.glDeleteShader(f)
        return p
    }

    private fun compile(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, src); GLES20.glCompileShader(s)
        val ok = IntArray(1); GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) Log.e(TAG, "compile: ${GLES20.glGetShaderInfoLog(s)}\n$src")
        return s
    }
}

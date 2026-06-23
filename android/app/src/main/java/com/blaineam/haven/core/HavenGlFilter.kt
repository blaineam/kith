package com.blaineam.haven.core

import com.daasuu.mp4compose.filter.GlFilter

/**
 * An mp4composer [GlFilter] whose fragment shader is generated from a [FilterSpec] — the SAME shader
 * the still-photo path ([GlPhotoFilter]) uses, so a filtered video matches a filtered photo (and the
 * iOS look) exactly. Uses the library's default vertex shader so frame orientation stays correct.
 */
class HavenGlFilter(spec: FilterSpec) :
    GlFilter(GlFilter.DEFAULT_VERTEX_SHADER, FilterShader.fragmentFor(spec))

package com.example.eaglenav.arcore

import android.opengl.GLES11Ext
import android.opengl.GLES20
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Minimal camera background renderer (OpenGL ES 2.0) based on the ARCore sample.
 *
 * Renders the ARCore camera texture (external OES) as a full-screen quad.
 */
class BackgroundRenderer {

  var textureId: Int = 0
    private set

  private var program = 0
  private var positionAttrib = 0
  private var texCoordAttrib = 0
  private var textureUniform = 0

  private val quadCoordsArray = floatArrayOf(
    -1f, -1f,
    1f, -1f,
    -1f, 1f,
    1f, 1f,
  )

  private val quadCoords: FloatBuffer = createFloatBuffer(quadCoordsArray)

  // Updated when display geometry changes.
  private var quadTexCoords: FloatBuffer = createFloatBuffer(
    floatArrayOf(
      0f, 1f,
      1f, 1f,
      0f, 0f,
      1f, 0f,
    ),
  )

  private val transformedTexCoords = FloatArray(8)

  fun createOnGlThread() {
    textureId = createExternalTexture()

    program = createProgram(VERTEX_SHADER, FRAGMENT_SHADER)
    positionAttrib = GLES20.glGetAttribLocation(program, "a_Position")
    texCoordAttrib = GLES20.glGetAttribLocation(program, "a_TexCoord")
    textureUniform = GLES20.glGetUniformLocation(program, "sTexture")
  }

  fun draw(frame: Frame) {
    // Update texture coordinates when the display geometry changes.
    if (frame.hasDisplayGeometryChanged()) {
      frame.transformCoordinates2d(
        Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES,
        quadCoordsArray,
        Coordinates2d.TEXTURE_NORMALIZED,
        transformedTexCoords,
      )
      quadTexCoords = createFloatBuffer(transformedTexCoords)
    }

    GLES20.glDisable(GLES20.GL_DEPTH_TEST)
    GLES20.glDepthMask(false)

    GLES20.glUseProgram(program)

    // Position
    quadCoords.position(0)
    GLES20.glVertexAttribPointer(
      positionAttrib,
      2,
      GLES20.GL_FLOAT,
      false,
      0,
      quadCoords,
    )
    GLES20.glEnableVertexAttribArray(positionAttrib)

    // Tex coords
    quadTexCoords.position(0)
    GLES20.glVertexAttribPointer(
      texCoordAttrib,
      2,
      GLES20.GL_FLOAT,
      false,
      0,
      quadTexCoords,
    )
    GLES20.glEnableVertexAttribArray(texCoordAttrib)

    // Texture
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
    GLES20.glUniform1i(textureUniform, 0)

    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

    GLES20.glDisableVertexAttribArray(positionAttrib)
    GLES20.glDisableVertexAttribArray(texCoordAttrib)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)

    GLES20.glDepthMask(true)
    GLES20.glEnable(GLES20.GL_DEPTH_TEST)
  }

  private fun createExternalTexture(): Int {
    val textures = IntArray(1)
    GLES20.glGenTextures(1, textures, 0)
    val id = textures[0]
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, id)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
    return id
  }

  private fun createProgram(vertex: String, fragment: String): Int {
    val v = compileShader(GLES20.GL_VERTEX_SHADER, vertex)
    val f = compileShader(GLES20.GL_FRAGMENT_SHADER, fragment)

    val program = GLES20.glCreateProgram()
    GLES20.glAttachShader(program, v)
    GLES20.glAttachShader(program, f)
    GLES20.glLinkProgram(program)

    val linkStatus = IntArray(1)
    GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
    if (linkStatus[0] == 0) {
      val log = GLES20.glGetProgramInfoLog(program)
      GLES20.glDeleteProgram(program)
      throw RuntimeException("Program link failed: $log")
    }
    return program
  }

  private fun compileShader(type: Int, code: String): Int {
    val shader = GLES20.glCreateShader(type)
    GLES20.glShaderSource(shader, code)
    GLES20.glCompileShader(shader)

    val compileStatus = IntArray(1)
    GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compileStatus, 0)
    if (compileStatus[0] == 0) {
      val log = GLES20.glGetShaderInfoLog(shader)
      GLES20.glDeleteShader(shader)
      throw RuntimeException("Shader compile failed: $log")
    }
    return shader
  }

  private fun createFloatBuffer(arr: FloatArray): FloatBuffer {
    val bb = ByteBuffer.allocateDirect(arr.size * 4)
    bb.order(ByteOrder.nativeOrder())
    val fb = bb.asFloatBuffer()
    fb.put(arr)
    fb.position(0)
    return fb
  }

  companion object {
    private const val VERTEX_SHADER = """
      attribute vec4 a_Position;
      attribute vec2 a_TexCoord;
      varying vec2 v_TexCoord;
      void main() {
        gl_Position = a_Position;
        v_TexCoord = a_TexCoord;
      }
    """

    private const val FRAGMENT_SHADER = """
      #extension GL_OES_EGL_image_external : require
      precision mediump float;
      uniform samplerExternalOES sTexture;
      varying vec2 v_TexCoord;
      void main() {
        gl_FragColor = texture2D(sTexture, v_TexCoord);
      }
    """
  }
}